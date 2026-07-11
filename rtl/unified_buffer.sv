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

    logic signed [DATA_WIDTH-1:0] mem [2][ROWS][COLS];

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

    // --- Host write → active bank ---
    always_ff @(posedge clk) begin
        if (host_write_valid)
            for (int c = 0; c < COLS; c++)
                mem[bank_sel][host_write_addr][c] <= host_write_data[c];
    end

    // --- Activation write → shadow bank ---
    always_ff @(posedge clk) begin
        if (act_write_valid)
            for (int c = 0; c < COLS; c++)
                mem[shadow_sel][act_write_ptr][c] <= act_write_data[c];
    end

    // --- Host read ← shadow bank (1-cycle latency) ---
    always_ff @(posedge clk) begin
        if (reset) begin
            host_read_valid <= 1'b0;
        end else begin
            host_read_valid <= host_read_en;
            if (host_read_en)
                for (int c = 0; c < COLS; c++)
                    host_read_data[c] <= mem[shadow_sel][host_read_addr][c];
        end
    end

    // --- UB read ← active bank (2-cycle latency, models M10K registered output) ---
    logic [ADDR_WIDTH-1:0] ub_addr_r;
    logic                  ub_en_r;
    logic                  ub_bank_r;   // snapshot bank_sel at request time

    always_ff @(posedge clk) begin
        if (reset) begin
            ub_en_r       <= 1'b0;
            ub_read_valid <= 1'b0;
        end else begin
            // Stage 1: register address, enable, and bank snapshot
            ub_addr_r <= ub_read_addr;
            ub_en_r   <= ub_read_en;
            ub_bank_r <= bank_sel;

            // Stage 2: read memory, register output
            ub_read_valid <= ub_en_r;
            if (ub_en_r)
                for (int c = 0; c < COLS; c++)
                    ub_read_data[c] <= mem[ub_bank_r][ub_addr_r][c];
        end
    end

endmodule
