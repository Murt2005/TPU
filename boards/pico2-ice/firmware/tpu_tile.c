/* SPI host link + FW_PROBE/FW_MATMUL offload for TPU_LINK_SPI builds (see README.md)
 * poll only between frames: a 0xFF filler mid-frame would land in the payload */

#if TPU_LINK_SPI

#include <stdint.h>
#include <stdbool.h>

#include "pico/stdlib.h"
#include "hardware/spi.h"
#include "hardware/gpio.h"
#include "hardware/timer.h"

#include "ice_usb.h"

#include "tpu_tile.h"

#define TPU_SPI          spi0
#define TPU_SPI_RX_PIN   4   /* RP2350 MISO <- net ICE_SI (iCE40 pin 17) */
#define TPU_SPI_CS_PIN   5   /* shared FPGA SSN + flash CS               */
#define TPU_SPI_SCK_PIN  6
#define TPU_SPI_TX_PIN   7   /* RP2350 MOSI -> net ICE_SO (iCE40 pin 14) */

#define TPU_SPI_WRITE_HZ 4000000   /* = 24 MHz FPGA clock / 6 */
#define TPU_SPI_READ_HZ  3000000   /* = 24 MHz FPGA clock / 8 */

/* wire protocol, checked against the RTL by make check-protocol */
#define CMD_LOAD_BIAS   0x02
#define CMD_STREAM_RUN  0x07
#define STATUS_OK       0xAA

/* captured here, never forwarded to the FPGA */
#define FW_MATMUL       0xF0
#define FW_PROBE        0xF1
#define FW_HDR_LEN      9
#define FW_MAGIC        'T'
#define FW_VERSION      1

/* only trips on a broken link or a gateware shape mismatch */
#define FPGA_RESP_TIMEOUT_US 100000

/* a host that dies mid-frame would desync every later session */
#define HOST_IDLE_RESET_US 1000000

/* -- SPI helpers ---------------------------------------------------------- */

static void tpu_cs(bool active) {
    gpio_put(TPU_SPI_CS_PIN, !active);
    sleep_us(1);   /* CS lead/lag: spi_slave needs >= 5 FPGA clk (~210 ns) */
}

static uint8_t tpu_spi_xfer_byte(uint8_t out) {
    uint8_t in;
    spi_write_read_blocking(TPU_SPI, &out, &in, 1);
    return in;
}

/* the flash shares CS with the FPGA: power it down, then drain the STATUS_ERR
 * the sequencer queues for the 0xB9 0x00 it also saw */
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

void tpu_tile_init(void) {
    spi_init(TPU_SPI, TPU_SPI_WRITE_HZ);
    gpio_set_function(TPU_SPI_RX_PIN, GPIO_FUNC_SPI);
    gpio_set_function(TPU_SPI_SCK_PIN, GPIO_FUNC_SPI);
    gpio_set_function(TPU_SPI_TX_PIN, GPIO_FUNC_SPI);
    gpio_init(TPU_SPI_CS_PIN);
    gpio_set_dir(TPU_SPI_CS_PIN, GPIO_OUT);
    gpio_put(TPU_SPI_CS_PIN, 1);

    tpu_spi_quiesce_flash();
}

/* -- CDC write with backpressure ----------------------------------------- */

static void cdc_write_all(const uint8_t *buf, uint32_t n) {
    for (uint32_t off = 0; off < n;) {
        uint32_t wrote = tud_cdc_n_write(ICE_USB_UART0_CDC, buf + off, n - off);
        off += wrote;
        if (wrote == 0) tud_task();   /* CDC FIFO full: let USB drain */
    }
    tud_cdc_n_write_flush(ICE_USB_UART0_CDC);
}

/* -- one FPGA transaction ------------------------------------------------- */
/* drain each response before the next frame: spi_slave's TX FIFO is shallow */
static bool fpga_transact(const uint8_t *frame, uint32_t flen,
                          uint8_t *payload, uint8_t *plen_out) {
    spi_set_baudrate(TPU_SPI, TPU_SPI_WRITE_HZ);
    tpu_cs(true);
    spi_write_blocking(TPU_SPI, frame, flen);
    tpu_cs(false);

    spi_set_baudrate(TPU_SPI, TPU_SPI_READ_HZ);
    uint32_t t0 = time_us_32();
    for (;;) {
        tpu_cs(true);
        uint8_t status = tpu_spi_xfer_byte(0xFF);
        if (status != 0x00) {
            /* the rest is already queued: the sequencer outpaces this read clock */
            uint8_t len = tpu_spi_xfer_byte(0xFF);
            for (uint32_t i = 0; i < len; i++) payload[i] = tpu_spi_xfer_byte(0xFF);
            tpu_cs(false);
            *plen_out = len;
            return status == STATUS_OK;
        }
        tpu_cs(false);
        if (time_us_32() - t0 > FPGA_RESP_TIMEOUT_US) return false;
        tud_task();
    }
}

/* -- FW_MATMUL state ------------------------------------------------------ */

/* generous caps (MNIST layer 1 needs W=9216); oversize requests get STATUS_ERR */
#define MAX_W_BYTES    (64 * 1024)
#define MAX_A_BYTES    (16 * 1024)
#define MAX_BIAS_BYTES (1024)
#define MAX_OUT_BYTES  (32 * 1024)

static uint8_t w_buf[MAX_W_BYTES];
static uint8_t a_buf[MAX_A_BYTES];
static uint8_t bias_buf[MAX_BIAS_BYTES];
static uint8_t out_buf[MAX_OUT_BYTES];

static struct {
    uint32_t m, k, n;
    uint32_t rows, cols, m_tile;
} dims;

static uint32_t w_len, bias_len, a_len;
static bool     bulk_ok;              /* dims accepted; else drain and ERR  */
static uint64_t bulk_total, bulk_got; /* u64: u16 dims can product past u32 */
static uint32_t bulk_csum;
static uint8_t  bulk_rx_csum;
static bool     bulk_active;

/* -- host-stream state machine -------------------------------------------- */
/* tracks [CMD][LEN][payload] framing so polls and FW capture happen between frames */
enum host_state { HS_CMD, HS_LEN, HS_PAYLOAD };
static enum host_state hs = HS_CMD;
static bool     fw_frame;        /* current frame is FW_MATMUL/FW_PROBE     */
static uint8_t  cur_cmd;
static uint32_t payload_left;
static uint8_t  hdr_buf[FW_HDR_LEN];
static uint32_t hdr_got;
static uint32_t last_rx_us;

/* batched into one CS frame */
static uint8_t  fwd_buf[64];
static uint32_t fwd_n;

static void fwd_flush(void) {
    if (fwd_n == 0) return;
    spi_set_baudrate(TPU_SPI, TPU_SPI_WRITE_HZ);
    tpu_cs(true);
    spi_write_blocking(TPU_SPI, fwd_buf, fwd_n);
    tpu_cs(false);
    fwd_n = 0;
}

static void fwd_byte(uint8_t b) {
    fwd_buf[fwd_n++] = b;
    if (fwd_n == sizeof fwd_buf) fwd_flush();
}

static void fw_respond(uint8_t status) {
    uint8_t hdr[2] = { status, 0x00 };
    cdc_write_all(hdr, 2);
}

/* port of the host's matmul_tiled(); padding happens in the gather, never copied */
static bool fw_run_tiles(void) {
    const uint32_t rows = dims.rows, cols = dims.cols, mt = dims.m_tile;
    const uint32_t stb = rows * cols + mt * rows;   /* stream_tile_bytes */
    const uint32_t mst = 253 / stb;                 /* max_stream_tiles  */
    const uint32_t mp = (dims.m + mt - 1) / mt * mt;
    const uint32_t kp = (dims.k + rows - 1) / rows * rows;
    const uint32_t np = (dims.n + cols - 1) / cols * cols;
    const uint32_t nkt = kp / rows;                 /* num_k_tiles       */

    uint8_t frame[2 + 255], resp[255], plen;

    for (uint32_t m0 = 0; m0 < mp; m0 += mt) {
        for (uint32_t n0 = 0; n0 < np; n0 += cols) {
            uint32_t p = 0;
            frame[p++] = CMD_LOAD_BIAS;
            frame[p++] = (uint8_t)(2 * cols);
            for (uint32_t c = 0; c < cols; c++) {
                uint32_t gn = n0 + c;
                frame[p++] = gn < dims.n ? bias_buf[2 * gn] : 0;
                frame[p++] = gn < dims.n ? bias_buf[2 * gn + 1] : 0;
            }
            if (!fpga_transact(frame, p, resp, &plen)) return false;

            for (uint32_t c0 = 0; c0 < nkt; c0 += mst) {
                uint32_t c1 = c0 + mst < nkt ? c0 + mst : nkt;
                p = 0;
                frame[p++] = CMD_STREAM_RUN;
                frame[p++] = (uint8_t)(2 + (c1 - c0) * stb);
                frame[p++] = (uint8_t)((c0 == 0 ? 0x01 : 0) |   /* TILE_FIRST */
                                       (c1 == nkt ? 0x02 : 0)); /* TILE_LAST  */
                frame[p++] = (uint8_t)(c1 - c0);
                for (uint32_t t = c0; t < c1; t++) {
                    uint32_t k0 = t * rows;
                    /* weight tile: natural row-major, like run_tile() */
                    for (uint32_t r = 0; r < rows; r++)
                        for (uint32_t c = 0; c < cols; c++) {
                            uint32_t gk = k0 + r, gn = n0 + c;
                            frame[p++] = (gk < dims.k && gn < dims.n)
                                       ? w_buf[gk * dims.n + gn] : 0;
                        }
                    for (uint32_t i = 0; i < mt; i++)
                        for (uint32_t r = 0; r < rows; r++) {
                            uint32_t gm = m0 + i, gk = k0 + r;
                            frame[p++] = (gm < dims.m && gk < dims.k)
                                       ? a_buf[gm * dims.k + gk] : 0;
                        }
                }
                if (!fpga_transact(frame, p, resp, &plen)) return false;
                tud_task();   /* keep USB serviced through a long matmul */

                if (c1 == nkt) {   /* TILE_LAST response carries the block */
                    if (plen != 2 * mt * cols) return false;
                    for (uint32_t i = 0; i < mt; i++)
                        for (uint32_t c = 0; c < cols; c++) {
                            uint32_t gm = m0 + i, gn = n0 + c;
                            if (gm < dims.m && gn < dims.n) {
                                out_buf[2 * (gm * dims.n + gn)]     = resp[2 * (i * cols + c)];
                                out_buf[2 * (gm * dims.n + gn) + 1] = resp[2 * (i * cols + c) + 1];
                            }
                        }
                }
            }
        }
    }
    return true;
}

static void fw_matmul_exec(void) {
    if (!bulk_ok || (bulk_csum & 0xFF) != bulk_rx_csum || !fw_run_tiles()) {
        fw_respond(0xFF);
        return;
    }
    fw_respond(STATUS_OK);
    cdc_write_all(out_buf, 2 * dims.m * dims.n);
}

static void fw_matmul_start(void) {
    dims.m      = (uint32_t)hdr_buf[0] | (uint32_t)hdr_buf[1] << 8;
    dims.k      = (uint32_t)hdr_buf[2] | (uint32_t)hdr_buf[3] << 8;
    dims.n      = (uint32_t)hdr_buf[4] | (uint32_t)hdr_buf[5] << 8;
    dims.rows   = hdr_buf[6];
    dims.cols   = hdr_buf[7];
    dims.m_tile = hdr_buf[8];

    w_len    = dims.k * dims.n;
    bias_len = 2 * dims.n;
    a_len    = dims.m * dims.k;

    uint32_t stb = dims.rows * dims.cols + dims.m_tile * dims.rows;
    bulk_ok = dims.m && dims.k && dims.n
           && dims.rows && dims.cols && dims.m_tile
           && stb <= 253                      /* >= 1 tile per STREAM_RUN  */
           && 2 * dims.cols <= 255            /* LOAD_BIAS payload fits    */
           && w_len <= MAX_W_BYTES && a_len <= MAX_A_BYTES
           && bias_len <= MAX_BIAS_BYTES
           && (uint64_t)2 * dims.m * dims.n <= MAX_OUT_BYTES;

    bulk_total  = (uint64_t)w_len + bias_len + a_len + 1;
    bulk_got    = 0;
    bulk_csum   = 0;
    bulk_active = true;
}

static void fw_frame_complete(void) {
    if (cur_cmd == FW_PROBE) {
        uint8_t resp[4] = { STATUS_OK, 0x02, FW_MAGIC, FW_VERSION };
        cdc_write_all(resp, sizeof resp);
    } else if (hdr_got == FW_HDR_LEN) {
        fw_matmul_start();
    } else {
        fw_respond(0xFF);   /* FW_MATMUL with a wrong-sized header */
    }
}

static void bulk_accept(uint8_t b) {
    uint64_t off = bulk_got++;
    if (off < bulk_total - 1) {
        bulk_csum += b;
        if (bulk_ok) {
            if (off < w_len)                  w_buf[off] = b;
            else if (off < w_len + bias_len)  bias_buf[off - w_len] = b;
            else                              a_buf[off - w_len - bias_len] = b;
        }
    } else {
        bulk_rx_csum = b;
    }
    if (bulk_got == bulk_total) {
        bulk_active = false;
        fw_matmul_exec();
    }
}

static void host_byte(uint8_t b) {
    if (bulk_active) {
        bulk_accept(b);
        return;
    }
    switch (hs) {
        case HS_CMD:
            if (b == 0xFF) { fwd_byte(b); return; }  /* 0xFF = NOP filler */
            cur_cmd = b;
            fw_frame = (b == FW_MATMUL || b == FW_PROBE);
            if (!fw_frame) fwd_byte(b);
            hs = HS_LEN;
            return;
        case HS_LEN:
            payload_left = b;
            hdr_got = 0;
            if (!fw_frame) fwd_byte(b);
            if (payload_left == 0) {
                hs = HS_CMD;
                if (fw_frame) fw_frame_complete();
            } else {
                hs = HS_PAYLOAD;
            }
            return;
        case HS_PAYLOAD:
            if (fw_frame) {
                if (hdr_got < sizeof hdr_buf) hdr_buf[hdr_got] = b;
                hdr_got++;
            } else {
                fwd_byte(b);
            }
            if (--payload_left == 0) {
                hs = HS_CMD;
                if (fw_frame) fw_frame_complete();
            }
            return;
    }
}

void tpu_tile_service(void) {
    if (!tud_cdc_n_connected(ICE_USB_UART0_CDC)) {
        return;   /* no host session: leave the bus alone (DFU may use it) */
    }

    uint8_t buf[64];
    uint32_t n = tud_cdc_n_read(ICE_USB_UART0_CDC, buf, sizeof buf);
    if (n > 0) {
        last_rx_us = time_us_32();
        for (uint32_t i = 0; i < n; i++) host_byte(buf[i]);
        fwd_flush();
        return;   /* service tud_task() again before considering a poll */
    }

    if (bulk_active || hs != HS_CMD) {
        /* mid-frame: no poll filler, but resync if the host went away */
        if (time_us_32() - last_rx_us > HOST_IDLE_RESET_US) {
            bulk_active = false;
            hs = HS_CMD;
        }
        return;
    }


    spi_set_baudrate(TPU_SPI, TPU_SPI_READ_HZ);
    tpu_cs(true);
    uint8_t status = tpu_spi_xfer_byte(0xFF);
    if (status != 0x00) {
        uint8_t len = tpu_spi_xfer_byte(0xFF);
        uint8_t resp[2 + 255];
        resp[0] = status;
        resp[1] = len;
        for (uint32_t i = 0; i < len; i++) resp[2 + i] = tpu_spi_xfer_byte(0xFF);
        tpu_cs(false);
        cdc_write_all(resp, 2u + len);
    } else {
        tpu_cs(false);
    }
}

#endif  /* TPU_LINK_SPI */
