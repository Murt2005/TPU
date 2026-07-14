`timescale 1ns / 1ps

// Double-banked on-chip activation store.
//
// Two banks of mem[ROWS][COLS] (int8). One bank is the "active" bank that
// systolic_data_setup reads from; the other is the "shadow" bank that the
// activation unit writes into. The FSM pulses bank_swap once per layer
// boundary to atomically exchange the two roles.
//
// Read latencies
//   ub_read   (active bank → SDS)      : 2 cycles after ub_read_en   (models M10K)
//   host_read (shadow bank → ARM)       : 1 cycle  after host_read_en
//
// The act_write_ptr is a self-incrementing row counter; pulse
// act_write_addr_reset to zero it at the start of each layer.
module unified_buffer #(
    parameter int ROWS       = 2,
    parameter int COLS       = 2,
    parameter int DATA_WIDTH = 8,
    parameter int ADDR_WIDTH = $clog2(ROWS)
) (
    input  logic clk,
    input  logic reset,

    // Host write port (ARM loads input activation matrix before inference)
    input  logic [ADDR_WIDTH-1:0]         host_write_addr,
    input  logic signed [COLS-1:0][DATA_WIDTH-1:0] host_write_data,
    input  logic                          host_write_valid,

    // Host read port (ARM reads result after DONE), 1-cycle latency
    input  logic [ADDR_WIDTH-1:0]         host_read_addr,
    output logic signed [COLS-1:0][DATA_WIDTH-1:0] host_read_data,
    input  logic                          host_read_en,
    output logic                          host_read_valid,

    // Systolic data setup read port, 2-cycle latency
    input  logic [ADDR_WIDTH-1:0]         ub_read_addr,
    input  logic                          ub_read_en,
    output logic signed [COLS-1:0][DATA_WIDTH-1:0] ub_read_data,
    output logic                          ub_read_valid,

    // Activation write port: address auto-increments on each valid pulse
    input  logic signed [COLS-1:0][DATA_WIDTH-1:0] act_write_data,
    input  logic                          act_write_valid,
    input  logic                          act_write_addr_reset,

    // FSM pulses once per layer boundary to swap active / shadow banks
    input  logic                          bank_swap
);

    // Two banks as two separate 1W1R memories with a flat word per row, so
    // yosys memory inference can map each one onto block RAM instead of a
    // fabric register file (the original mem[2][ROWS][COLS] had two write
    // processes into one array -- unmappable, so it burned ~667 LUT4 +
    // ~329 DFF at the 4x4/M_TILE=4 shape). At any instant each bank has
    // exactly one writer and one reader: the ACTIVE bank (bank_sel) is
    // host-written / ub-read, the SHADOW bank (~bank_sel) is act-written /
    // host-read, and bank_swap only exchanges the roles between phases.
    localparam int WORD_W = COLS * DATA_WIDTH;

    // ram_style: the buffer is far smaller than one 4Kbit block, so yosys's
    // efficiency heuristic would otherwise keep it in fabric FFs -- but the
    // LCs are the scarce resource here (4x4/M_TILE=4 is at the packing
    // limit) and 29 of the 30 BRAMs are idle.
    (* ram_style = "block" *) logic [WORD_W-1:0] mem0 [ROWS];
    (* ram_style = "block" *) logic [WORD_W-1:0] mem1 [ROWS];

    // bank_sel = index of the active bank (SDS reads from it; host writes before inference)
    // ~bank_sel = shadow bank (activation writes to it; host reads after inference)
    logic bank_sel;
    wire  shadow_sel = bank_sel ^ 1'b1;

    logic [ADDR_WIDTH-1:0] act_write_ptr;

    // --- Bank select ---
    always_ff @(posedge clk) begin
        if (reset)          bank_sel <= 1'b0;
        else if (bank_swap) bank_sel <= shadow_sel;
    end

    // --- Activation write pointer ---
    always_ff @(posedge clk) begin
        if (reset || act_write_addr_reset)
            act_write_ptr <= '0;
        else if (act_write_valid)
            act_write_ptr <= act_write_ptr + 1'b1;
    end

    // --- Write ports: host -> active bank, activation -> shadow bank ---
    wire                  wen0   = (bank_sel == 1'b0) ? host_write_valid : act_write_valid;
    wire [ADDR_WIDTH-1:0] waddr0 = (bank_sel == 1'b0) ? host_write_addr  : act_write_ptr;
    wire [WORD_W-1:0]     wdata0 = (bank_sel == 1'b0) ? host_write_data  : act_write_data;
    wire                  wen1   = (bank_sel == 1'b1) ? host_write_valid : act_write_valid;
    wire [ADDR_WIDTH-1:0] waddr1 = (bank_sel == 1'b1) ? host_write_addr  : act_write_ptr;
    wire [WORD_W-1:0]     wdata1 = (bank_sel == 1'b1) ? host_write_data  : act_write_data;

    always_ff @(posedge clk) if (wen0) mem0[waddr0] <= wdata0;
    always_ff @(posedge clk) if (wen1) mem1[waddr1] <= wdata1;

    // --- Read ports ---
    // Port-latency contract is unchanged: host_read data lands 1 cycle
    // after host_read_en (the banks' sync read IS that register); ub_read
    // data lands 2 cycles after ub_read_en (stage 1 registers the address
    // and bank snapshot in fabric, stage 2 is the banks' sync read).
    logic [ADDR_WIDTH-1:0] ub_addr_r;
    logic                  ub_en_r;
    logic                  ub_bank_r;   // snapshot bank_sel at request time

    always_ff @(posedge clk) begin
        if (reset) begin
            ub_en_r <= 1'b0;
        end else begin
            ub_addr_r <= ub_read_addr;
            ub_en_r   <= ub_read_en;
            ub_bank_r <= bank_sel;
        end
    end

    // Each bank's single read port goes to the ub pipeline when an
    // in-flight ub read targets it (its snapshot bank), else to the host
    // port -- the two consumers own opposite banks by construction.
    wire [ADDR_WIDTH-1:0] raddr0 = (ub_en_r && ub_bank_r == 1'b0) ? ub_addr_r : host_read_addr;
    wire [ADDR_WIDTH-1:0] raddr1 = (ub_en_r && ub_bank_r == 1'b1) ? ub_addr_r : host_read_addr;

    logic [WORD_W-1:0] rdata0, rdata1;
    always_ff @(posedge clk) rdata0 <= mem0[raddr0];
    always_ff @(posedge clk) rdata1 <= mem1[raddr1];

    // Result-side select registers, aligned to when the banks' read
    // registers carry each consumer's data.
    logic ub_bank_rr;    // bank of the ub read now sitting in rdata0/1
    logic host_bank_r;   // bank of the host read now sitting in rdata0/1

    always_ff @(posedge clk) begin
        if (reset) begin
            ub_read_valid   <= 1'b0;
            host_read_valid <= 1'b0;
        end else begin
            ub_read_valid   <= ub_en_r;
            ub_bank_rr      <= ub_bank_r;
            host_read_valid <= host_read_en;
            if (host_read_en) host_bank_r <= shadow_sel;
        end
    end

    assign ub_read_data   = ub_bank_rr  ? rdata1 : rdata0;
    assign host_read_data = host_bank_r ? rdata1 : rdata0;

endmodule
