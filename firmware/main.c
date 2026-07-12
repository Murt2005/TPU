/*
 * pico2_ice_bridge -- fork of pico-ice-sdk/examples/rp2_usb_uart, changed
 * to export a 12 MHz clock to the iCE40 instead of the SDK's 48 MHz
 * default. tpu_top's fMax on the UP5K is ~32 MHz (see fpga/pico2_ice/), and
 * CLK_FREQ there must match whatever this firmware requests here -- the
 * UART baud-rate divider is computed from CLK_FREQ at synthesis time, so a
 * mismatch means garbled bytes even though the logic itself is correct.
 *
 * Otherwise unchanged: ice_usb_init() wires up two USB-CDC ports ("RP2040
 * logs" and "iCE40 UART", per usb_descriptors.c) plus a DFU interface for
 * flashing the FPGA gateware (see ../../fpga/pico2_ice/Makefile's `prog`
 * target). "iCE40 UART" bridges to the RP2350's hardware uart0 peripheral,
 * which the board wires to iCE40 pins 9/11 (DEFAULT_UART_RX/TX in
 * pico-ice-sdk/rtl/pico2_ice.pcf) -- the same pins fpga/pico2_ice/tpu_top.pcf
 * maps tpu_top's rx_pin/tx_pin to.
 *
 * UART_TX_PIN/UART_RX_PIN are 28/29, NOT the 0/1 the upstream rp2_usb_uart
 * example uses. That example targets the original pico-ice (RP2040); on
 * pico2-ice, RP2350 GPIO0/GPIO1 are wired to the onboard LED (LED_G/LED_R),
 * not the FPGA. Confirmed against the board schematic
 * (Board/Rev1/pico2-ice.pdf in the tinyvision-ai-inc/pico2-ice repo): the
 * RP2350 pin table there shows GPIO28 -> ICE_9 and GPIO29 -> ICE_11, which
 * are exactly the iCE40 pins tpu_top.pcf calls rx_pin/tx_pin.
 */

// pico-sdk
#include "pico/stdio.h"
#include "hardware/irq.h"
#include "hardware/gpio.h"
#include "hardware/uart.h"
#if TPU_LINK_SPI
#include "hardware/spi.h"
#endif

// pico-ice-sdk
#include "ice_usb.h"
#include "ice_fpga.h"
#include "ice_led.h"

#define UART_TX_PIN 28
#define UART_RX_PIN 29

#if TPU_LINK_SPI
/*
 * ---- SPI bridge (TPU_LINK_SPI=1 builds; pairs with USE_SPI=1 gateware) ----
 *
 * Bridges the "iCE40 UART" CDC port to spi0 on the shared RP2350<->iCE40
 * config bus instead of uart0 (GPIO numbers from pico-ice-sdk
 * src/ice_fpga_data.c's pico2_spibus; the iCE40-side pins are in
 * fpga/tpu_top.pcf). SPI is master-driven, so responses are READ by
 * polling: after a complete command frame has been forwarded, the bridge
 * clocks 0xFF filler (CMD_NOP, ignored by the sequencer) and watches MISO
 * for the first non-0x00 byte = STATUS, then forwards LEN and the payload
 * (rtl/spi_slave.sv's write-then-poll protocol).
 *
 * Two invariants keep this correct:
 *  - Never poll mid-command-frame: a poll's 0xFF would land in the middle
 *    of the frame's payload bytes. The bridge tracks [CMD][LEN][payload]
 *    framing of the host stream (frame_phase below) and polls only
 *    between frames.
 *  - The SPI flash shares this bus AND the same chip-select net as the
 *    FPGA's SSN, so every asserted CS selects both. The flash is put into
 *    deep power-down once at startup (0xB9; it then ignores everything
 *    until a release command, and 0xAB never appears as a first-in-frame
 *    byte in this protocol), and the stale STATUS_ERR the FPGA queues in
 *    response to that 0xB9 frame is drained before the main loop starts.
 *
 * Clock caps (both scale with the FPGA core clock, 12 MHz today):
 *  - write <= FPGA_CLK/6: the sequencer drops RX bytes during its
 *    inter-tile STREAM_RUN processing window (~35 clk) — same timing
 *    assumption its header documents for UART.
 *  - read  <= FPGA_CLK/8: spi_slave's TX engine samples SCK through a
 *    2FF synchronizer in the FPGA core-clock domain.
 */
#define TPU_SPI          spi0
#define TPU_SPI_RX_PIN   4   /* RP2350 MISO <- net ICE_SI (iCE40 pin 17) */
#define TPU_SPI_CS_PIN   5   /* shared FPGA SSN + flash CS               */
#define TPU_SPI_SCK_PIN  6
#define TPU_SPI_TX_PIN   7   /* RP2350 MOSI -> net ICE_SO (iCE40 pin 14) */

#define TPU_SPI_WRITE_HZ 2000000
#define TPU_SPI_READ_HZ  1500000

static void tpu_cs(bool active) {
    gpio_put(TPU_SPI_CS_PIN, !active);
    sleep_us(1);   /* CS lead/lag: spi_slave needs >= 5 FPGA clk (~420 ns) */
}

static void tpu_spi_init(void) {
    spi_init(TPU_SPI, TPU_SPI_WRITE_HZ);
    gpio_set_function(TPU_SPI_RX_PIN, GPIO_FUNC_SPI);
    gpio_set_function(TPU_SPI_SCK_PIN, GPIO_FUNC_SPI);
    gpio_set_function(TPU_SPI_TX_PIN, GPIO_FUNC_SPI);
    gpio_init(TPU_SPI_CS_PIN);
    gpio_set_dir(TPU_SPI_CS_PIN, GPIO_OUT);
    gpio_put(TPU_SPI_CS_PIN, 1);
}

static uint8_t tpu_spi_xfer_byte(uint8_t out) {
    uint8_t in;
    spi_write_read_blocking(TPU_SPI, &out, &in, 1);
    return in;
}

// Flash deep power-down + drain of the FPGA's resulting error response
// (the FPGA slave also sees the 0xB9 frame: 0xB9 parses as an unknown CMD
// and the trailing 0x00 as its LEN, so it queues one STATUS_ERR).
static void tpu_spi_quiesce_flash(void) {
    uint8_t dpd[2] = { 0xB9, 0x00 };
    tpu_cs(true);
    spi_write_blocking(TPU_SPI, dpd, 2);
    tpu_cs(false);

    spi_set_baudrate(TPU_SPI, TPU_SPI_READ_HZ);
    for (int i = 0, idle = 0; i < 64 && idle < 4; i++) {
        tpu_cs(true);
        uint8_t b = tpu_spi_xfer_byte(0xFF);
        tpu_cs(false);
        idle = (b == 0x00) ? idle + 1 : 0;
    }
}

// Host-stream frame tracker: 0 = expecting CMD, 1 = expecting LEN,
// >1 = (frame_remaining) payload bytes still owed. Polling is only safe
// in phase 0 — see the header comment.
static uint32_t frame_remaining = 0;
static uint8_t  frame_phase = 0;

static void tpu_track_host_byte(uint8_t b) {
    switch (frame_phase) {
        case 0: if (b != 0xFF) frame_phase = 1; break;  /* 0xFF = NOP filler */
        case 1:
            frame_remaining = b;
            frame_phase = frame_remaining ? 2 : 0;
            break;
        default:
            if (--frame_remaining == 0) frame_phase = 0;
            break;
    }
}

// One main-loop service step: forward pending host bytes, else (between
// frames only) poll for a queued response and forward it to CDC.
static void tpu_spi_service(void) {
    if (!tud_cdc_n_connected(ICE_USB_UART0_CDC)) {
        return;   /* no host session: leave the bus alone (DFU may use it) */
    }

    uint8_t buf[64];
    uint32_t n = tud_cdc_n_read(ICE_USB_UART0_CDC, buf, sizeof buf);
    if (n > 0) {
        spi_set_baudrate(TPU_SPI, TPU_SPI_WRITE_HZ);
        tpu_cs(true);
        spi_write_blocking(TPU_SPI, buf, n);
        tpu_cs(false);
        for (uint32_t i = 0; i < n; i++) tpu_track_host_byte(buf[i]);
        return;   /* service tud_task() again before considering a poll */
    }

    if (frame_phase != 0) {
        return;   /* mid-frame: never inject poll filler */
    }

    spi_set_baudrate(TPU_SPI, TPU_SPI_READ_HZ);
    tpu_cs(true);
    uint8_t status = tpu_spi_xfer_byte(0xFF);
    if (status != 0x00) {
        // Response started: LEN and payload bytes are already queued (the
        // sequencer pushes ~30x faster than this read clock drains).
        uint8_t len = tpu_spi_xfer_byte(0xFF);
        uint8_t resp[2 + 255];
        resp[0] = status;
        resp[1] = len;
        for (uint32_t i = 0; i < len; i++) resp[2 + i] = tpu_spi_xfer_byte(0xFF);
        tpu_cs(false);
        for (uint32_t off = 0; off < 2u + len;) {
            uint32_t wrote = tud_cdc_n_write(ICE_USB_UART0_CDC, resp + off,
                                             2u + len - off);
            off += wrote;
            if (wrote == 0) tud_task();   /* CDC FIFO full: let USB drain */
        }
        tud_cdc_n_write_flush(ICE_USB_UART0_CDC);
    } else {
        tpu_cs(false);
    }
}
#endif  /* TPU_LINK_SPI */

// Implemented in pico-ice-sdk/src/ice_fpga.c but not declared in ice_fpga.h.
extern int ice_fpga_configured(const ice_fpga fpga);

// Per-CDC-interface RX byte handlers, defined (non-static) in
// pico-ice-sdk/src/ice_usb.c so they can be replaced here.
extern void (*tud_cdc_rx_cb_table[])(uint8_t);

#if !TPU_LINK_SPI
// Replacement for the SDK's ice_usb_cdc_to_uart0(), which does
//     if (uart_is_writable(uart0)) { uart_putc(uart0, byte); }
// i.e. SILENTLY DROPS bytes once the RP2350's 32-deep UART TX FIFO is
// full. USB delivers bytes far faster than 115200 baud drains them, so any
// host write burst longer than the FIFO loses its tail -- fine for the TPU
// protocol's original <=11-byte frames, fatal for CMD_STREAM_RUN's frames
// of up to 253 bytes. Blocking here instead lets TinyUSB's CDC flow
// control (NAK when its 512-byte RX FIFO fills) push the backpressure all
// the way to the host, so no byte is ever lost regardless of frame size.
// The stall is bounded by the FIFO drain rate (~87 us/byte at 115200) and
// only delays tud_task() while a burst drains -- acceptable for this
// single-purpose bridge. (tpu_host.py also paces its writes to wire speed,
// so with a current host this path rarely even engages.)
static void cdc_to_uart0_blocking(uint8_t byte) {
    uart_putc_raw(uart0, byte);
}

// ---- uart0 -> CDC bridging, moved OUT of interrupt context ----
// ice_usb_init() installs the SDK's ice_usb_uart0_to_cdc() as the UART0 RX
// interrupt handler, and that handler calls tud_cdc_n_write_char() +
// tud_cdc_n_write_flush() directly from the ISR. TinyUSB's device API has
// no locking under CFG_TUSB_OS == OPT_OS_NONE, so an RX interrupt landing
// while the main loop is inside tud_task() races the CDC endpoint state.
// At 115200 that window was rarely hit; at 1 Mbaud a response byte arrives
// every ~10 us and the race is routine -- observed on real hardware as a
// response truncated after its first byte followed by the ENTIRE USB stack
// (CDC and DFU alike) hanging until power cycle. Standard fix: the ISR only
// moves bytes into a ring buffer, and the main loop -- the one and only
// TinyUSB caller -- forwards them to the CDC FIFO.
#define UART_RING_BITS 12   // 4096 bytes: outlasts any protocol response burst
static uint8_t  uart_ring[1u << UART_RING_BITS];
static volatile uint32_t ring_w, ring_r;   // SPSC: ISR produces, main consumes

static void uart0_rx_to_ring(void) {
    while (uart_is_readable(uart0)) {
        uint8_t byte = uart_getc(uart0);
        uint32_t next = (ring_w + 1) & ((1u << UART_RING_BITS) - 1);
        if (next != ring_r) {           // on overflow, drop (never in practice:
            uart_ring[ring_w] = byte;   // the ring dwarfs the largest response)
            ring_w = next;
        }
    }
}

static void drain_ring_to_cdc(void) {
    bool wrote = false;
    while (ring_r != ring_w && tud_cdc_n_write_available(ICE_USB_UART0_CDC) > 0) {
        tud_cdc_n_write_char(ICE_USB_UART0_CDC, uart_ring[ring_r]);
        ring_r = (ring_r + 1) & ((1u << UART_RING_BITS) - 1);
        wrote = true;
    }
    if (wrote) {
        tud_cdc_n_write_flush(ICE_USB_UART0_CDC);
    }
}
#endif  /* !TPU_LINK_SPI */

int main(void) {
#if !TPU_LINK_SPI
    // Enable the UART
    uart_init(uart0, 115200);
    gpio_set_function(UART_TX_PIN, GPIO_FUNC_UART);
    gpio_set_function(UART_RX_PIN, GPIO_FUNC_UART);
#endif

    // Configure the piping as configured in <tusb_config.h>
    ice_usb_init();

#if TPU_LINK_SPI
    // SPI bridge: the TPU CDC port is serviced by polling in the main loop
    // (tpu_spi_service), not by the SDK's per-byte RX callback -- a NULL
    // table entry leaves incoming bytes in the CDC FIFO for tud_cdc_n_read.
    tud_cdc_rx_cb_table[ICE_USB_UART0_CDC] = NULL;
#else
    // Swap in the non-dropping CDC->UART bridge (see comment above).
    tud_cdc_rx_cb_table[ICE_USB_UART0_CDC] = &cdc_to_uart0_blocking;

    // Swap the SDK's ISR-context CDC writer for the ring-buffer producer
    // (see the uart0_rx_to_ring comment above). ice_usb_init() claimed
    // UART0_IRQ exclusively, so release its handler before installing ours;
    // the SDK's uart_set_irq_enables(uart0, true, false) stays in effect.
    irq_set_enabled(UART0_IRQ, false);
    irq_remove_handler(UART0_IRQ, irq_get_exclusive_handler(UART0_IRQ));
    irq_set_exclusive_handler(UART0_IRQ, uart0_rx_to_ring);
    irq_set_enabled(UART0_IRQ, true);
#endif

    // Initialize the FPGA -- 12 MHz, not ICE_FPGA_DEFAULT_FREQUENCY (48 MHz):
    // must match fpga/pico2_ice/Makefile's CLK_FREQ.
    ice_fpga_init(FPGA_DATA, AS_MHZ(12));

    // Let the FPGA start
    ice_fpga_start(FPGA_DATA);

#if TPU_LINK_SPI
    // The FPGA just self-configured from flash over this same bus; now take
    // it over for the TPU link: claim the pins, park the flash in deep
    // power-down (it shares the CS net), and drain the FPGA's error
    // response to the power-down frame.
    tpu_spi_init();
    tpu_spi_quiesce_flash();
#endif

    // Independent CDONE check: ice_usb.c's DFU manifest callback reports
    // ok = ice_fpga_start(...), but ice_fpga_start() unconditionally
    // `return 0;` (never actually polls CDONE) -- 0 is falsy in C, so that
    // callback reports DFU_STATUS_ERR_FIRMWARE ("firmware corrupt") on
    // *every* flash, success or not. ice_fpga_configured() is the function
    // that actually polls CDONE with a timeout; it exists in the SDK but
    // isn't wired into this example. Use it here for a real answer, shown
    // on the LED: green = FPGA configured and running, red = it did not.
    ice_led_init();
    if (ice_fpga_configured(FPGA_DATA) == 0) {
        ice_led_green(true);
    } else {
        ice_led_red(true);
    }

    // Demo LED feedback: the "RP2040 logs" CDC port (interface 0) is
    // otherwise unused by this firmware -- ICE_USB_UART0_CDC (tusb_config.h)
    // bridges hardware uart0 (the TPU link) to CDC interface 1 ("iCE40
    // UART") only, so draining single-byte commands from interface 0 here
    // can't interfere with the TPU wire protocol. 'g'/'G' -> green (idle),
    // 'b'/'B' -> blue (inference complete). Lets a host script (e.g. the
    // MNIST drawing demo) flip the board's LED without touching the FPGA
    // datapath at all.
    while (true) {
        tud_task();
#if TPU_LINK_SPI
        tpu_spi_service();
#else
        drain_ring_to_cdc();
#endif

        int32_t ch = tud_cdc_n_read_char(0);
        if (ch == 'b' || ch == 'B') {
            ice_led_green(false);
            ice_led_blue(true);
        } else if (ch == 'g' || ch == 'G') {
            ice_led_blue(false);
            ice_led_green(true);
        }
    }
    return 0;
}
