/*
 * The MIT License (MIT)
 *
 * Copyright (c) 2019 Ha Thach (tinyusb.org)
 * Copyright (c) 2022 TinyVision.ai Inc.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */
#pragma once

// pico-ice-sdk
#include "boards.h"
#include "ice_flash.h"

#define BOARD_DEVICE_RHPORT_NUM     0

#define CFG_TUSB_RHPORT0_MODE       OPT_MODE_DEVICE

#define BOARD_DEVICE_RHPORT_SPEED   OPT_MODE_FULL_SPEED

#define CFG_TUD_ENABLED             1

#define CFG_TUD_MAX_SPEED           OPT_MODE_FULL_SPEED

// two CDC ports ("RP2040 logs", "iCE40 UART") + DFU with flash and CRAM alt settings
#define CFG_TUD_CDC                 2
#define CFG_TUD_MSC                 0
#define CFG_TUD_DFU                 1
#define CFG_TUD_DFU_ALT             2
#define CFG_TUD_HID                 0
#define CFG_TUD_MIDI                0
#define CFG_TUD_VENDOR              0

// SDK bridges uart0 to CDC port 1; main.c replaces both directions
#define ICE_USB_UART0_CDC           1

#define CFG_TUD_CDC_RX_BUFSIZE      512
#define CFG_TUD_CDC_TX_BUFSIZE      512
#define CFG_TUD_CDC_EP_BUFSIZE      512

#define CFG_TUD_MSC_BUFSIZE         ICE_FLASH_SECTOR_SIZE

// must be a multiple of the flash page size
#define CFG_TUD_DFU_XFER_BUFSIZE    256
