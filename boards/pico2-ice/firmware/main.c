// pico2_ice_bridge: USB bridge, FPGA clock + bitstream loader (see README.md)

// pico-sdk
#include "pico/stdio.h"
#include "hardware/irq.h"
#include "hardware/gpio.h"
#include "hardware/uart.h"

// pico-ice-sdk
#include "ice_usb.h"
#include "ice_fpga.h"
#include "ice_led.h"

#include "tpu_tile.h"

// GPIO28/29, not the upstream example's 0/1: those are the LEDs on pico2-ice
#define UART_TX_PIN 28
#define UART_RX_PIN 29

// in pico-ice-sdk/src/ice_fpga.c but not its header
extern int ice_fpga_configured(const ice_fpga fpga);

// per-CDC RX handlers from pico-ice-sdk/src/ice_usb.c, replaced below
extern void (*tud_cdc_rx_cb_table[])(uint8_t);

#if !TPU_LINK_SPI
// the SDK's version drops bytes once the 32-deep TX FIFO fills; blocking lets
// TinyUSB flow control push back to the host instead
static void cdc_to_uart0_blocking(uint8_t byte) {
    uart_putc_raw(uart0, byte);
}

// the SDK writes to TinyUSB from the UART ISR, which races tud_task() and wedged
// the whole USB stack at 1 Mbaud; the ISR only fills a ring, the main loop drains it
#define UART_RING_BITS 12   // 4 KB, larger than any response burst
static uint8_t  uart_ring[1u << UART_RING_BITS];
static volatile uint32_t ring_w, ring_r;   // SPSC: ISR produces, main consumes

static void uart0_rx_to_ring(void) {
    while (uart_is_readable(uart0)) {
        uint8_t byte = uart_getc(uart0);
        uint32_t next = (ring_w + 1) & ((1u << UART_RING_BITS) - 1);
        if (next != ring_r) {           // drop on overflow; never happens in practice
            uart_ring[ring_w] = byte;
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
    // the host's CDC line coding sets the real baud rate
    uart_init(uart0, 115200);
    gpio_set_function(UART_TX_PIN, GPIO_FUNC_UART);
    gpio_set_function(UART_RX_PIN, GPIO_FUNC_UART);
#endif

    ice_usb_init();

#if TPU_LINK_SPI
    // NULL leaves bytes in the CDC FIFO for tpu_tile_service() to poll
    tud_cdc_rx_cb_table[ICE_USB_UART0_CDC] = NULL;
#else
    tud_cdc_rx_cb_table[ICE_USB_UART0_CDC] = &cdc_to_uart0_blocking;

    // ice_usb_init() claimed UART0_IRQ exclusively, so remove its handler first
    irq_set_enabled(UART0_IRQ, false);
    irq_remove_handler(UART0_IRQ, irq_get_exclusive_handler(UART0_IRQ));
    irq_set_exclusive_handler(UART0_IRQ, uart0_rx_to_ring);
    irq_set_enabled(UART0_IRQ, true);
#endif

    // must match the gateware's CLK_FREQ, not the SDK's 48 MHz default
#if TPU_LINK_SPI
    ice_fpga_init(FPGA_DATA, AS_MHZ(TPU_TILE_FPGA_CLK_MHZ));
#else
    ice_fpga_init(FPGA_DATA, AS_MHZ(12));
#endif

    ice_fpga_start(FPGA_DATA);

#if TPU_LINK_SPI
    tpu_tile_init();
#endif

    // the real CDONE check: dfu-util's "firmware corrupt" is an SDK false alarm
    ice_led_init();
    if (ice_fpga_configured(FPGA_DATA) == 0) {
        ice_led_green(true);
    } else {
        ice_led_red(true);
    }

    // CDC port 0 is otherwise idle: one-byte LED commands for the draw demo
    while (true) {
        tud_task();
#if TPU_LINK_SPI
        tpu_tile_service();
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
