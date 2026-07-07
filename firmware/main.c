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

int main(void) {
    // Enable the UART
    uart_init(uart0, 115200);
    gpio_set_function(UART_TX_PIN, GPIO_FUNC_UART);
    gpio_set_function(UART_RX_PIN, GPIO_FUNC_UART);

    // Configure the piping as configured in <tusb_config.h>
    ice_usb_init();

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
