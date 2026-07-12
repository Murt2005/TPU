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

// pico-ice-sdk
#include "ice_usb.h"
#include "ice_fpga.h"
#include "ice_led.h"

#define UART_TX_PIN 28
#define UART_RX_PIN 29

// Implemented in pico-ice-sdk/src/ice_fpga.c but not declared in ice_fpga.h.
extern int ice_fpga_configured(const ice_fpga fpga);

// Per-CDC-interface RX byte handlers, defined (non-static) in
// pico-ice-sdk/src/ice_usb.c so they can be replaced here.
extern void (*tud_cdc_rx_cb_table[])(uint8_t);

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

int main(void) {
    // Enable the UART
    uart_init(uart0, 115200);
    gpio_set_function(UART_TX_PIN, GPIO_FUNC_UART);
    gpio_set_function(UART_RX_PIN, GPIO_FUNC_UART);

    // Configure the piping as configured in <tusb_config.h>
    ice_usb_init();

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

    // Initialize the FPGA -- 12 MHz, not ICE_FPGA_DEFAULT_FREQUENCY (48 MHz):
    // must match fpga/pico2_ice/Makefile's CLK_FREQ.
    ice_fpga_init(FPGA_DATA, AS_MHZ(12));

    // Let the FPGA start
    ice_fpga_start(FPGA_DATA);

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
        drain_ring_to_cdc();

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
