`timescale 1ns / 1ps

// pe_pair_tb — equivalence testbench.
//
// Instantiates one pe_pair (whose SB_MAC16 comes from yosys's ice40
// cells_sim.v, i.e. the exact netlist primitive that ships to hardware)
// next to two chained behavioral pe.sv references wired the way mmu.sv
// wires adjacent rows of a column:
//
//   TB ──weight──▶ top PE ──weight──▶ bottom PE
//   TB ──psum────▶ top PE ──psum────▶ bottom PE
//   TB ──act_t───▶ top PE            (activations are per-row,
//   TB ──act_b────────────▶ bottom PE  both driven by the TB)
//
// Each design's bottom PE is fed from its OWN top PE's outputs, and
// every output of the pair is compared against the references on every
// falling clock edge after reset release — pe_pair must be cycle-
// accurate bit-exact through randomized weight-loading bursts, valid
// bubbles, psum pass-through, and int8 boundary values.

module pe_pair_tb;

    logic clk = 1'b0;
    logic reset = 1'b1;
    logic loading_phase  = 1'b0;
    logic capture_weight = 1'b0;

    // TB-driven stimulus (shared by uut and reference chain)
    logic signed [7:0]  act_t = '0, act_b = '0;
    logic               act_valid_t = 1'b0, act_valid_b = 1'b0;
    logic signed [15:0] psum_in = '0;
    logic               psum_valid_in = 1'b0;
    logic signed [7:0]  weight_in = '0;
    logic               weight_valid_in = 1'b0;

    // ---------------- uut: pe_pair ----------------
    logic signed [7:0]  u_oa_t, u_oa_b, u_ow_t, u_ow_b;
    logic               u_oav_t, u_oav_b, u_owv_t, u_owv_b;
    logic signed [15:0] u_ops_t, u_ops_b;
    logic               u_opsv_t, u_opsv_b;

    pe_pair uut (
        .clk(clk), .reset(reset),
        .loading_phase(loading_phase), .capture_weight(capture_weight),

        .in_activation_t(act_t),   .in_activation_valid_t(act_valid_t),
        .out_activation_t(u_oa_t), .out_activation_valid_t(u_oav_t),
        .in_partial_sum_t(psum_in), .in_partial_sum_valid_t(psum_valid_in),
        .out_partial_sum_t(u_ops_t), .out_partial_sum_valid_t(u_opsv_t),
        .in_weight_t(weight_in),   .in_weight_valid_t(weight_valid_in),
        .out_weight_t(u_ow_t),     .out_weight_valid_t(u_owv_t),

        .in_activation_b(act_b),   .in_activation_valid_b(act_valid_b),
        .out_activation_b(u_oa_b), .out_activation_valid_b(u_oav_b),
        .in_partial_sum_b(u_ops_t), .in_partial_sum_valid_b(u_opsv_t),
        .out_partial_sum_b(u_ops_b), .out_partial_sum_valid_b(u_opsv_b),
        .in_weight_b(u_ow_t),      .in_weight_valid_b(u_owv_t),
        .out_weight_b(u_ow_b),     .out_weight_valid_b(u_owv_b)
    );

    // ---------------- reference: two behavioral pe.sv ----------------
    logic signed [7:0]  r_oa_t, r_oa_b, r_ow_t, r_ow_b;
    logic               r_oav_t, r_oav_b, r_owv_t, r_owv_b;
    logic signed [15:0] r_ops_t, r_ops_b;
    logic               r_opsv_t, r_opsv_b;

    pe ref_t (
        .clk(clk), .reset(reset),
        .loading_phase(loading_phase), .capture_weight(capture_weight),
        .in_activation(act_t),   .in_activation_valid(act_valid_t),
        .out_activation(r_oa_t), .out_activation_valid(r_oav_t),
        .in_partial_sum(psum_in), .in_partial_sum_valid(psum_valid_in),
        .out_partial_sum(r_ops_t), .out_partial_sum_valid(r_opsv_t),
        .in_weight(weight_in),   .in_weight_valid(weight_valid_in),
        .out_weight(r_ow_t),     .out_weight_valid(r_owv_t)
    );

    pe ref_b (
        .clk(clk), .reset(reset),
        .loading_phase(loading_phase), .capture_weight(capture_weight),
        .in_activation(act_b),   .in_activation_valid(act_valid_b),
        .out_activation(r_oa_b), .out_activation_valid(r_oav_b),
        .in_partial_sum(r_ops_t), .in_partial_sum_valid(r_opsv_t),
        .out_partial_sum(r_ops_b), .out_partial_sum_valid(r_opsv_b),
        .in_weight(r_ow_t),      .in_weight_valid(r_owv_t),
        .out_weight(r_ow_b),     .out_weight_valid(r_owv_b)
    );

    always #5 clk = ~clk;

    int errors = 0;
    int checks = 0;
    bit checking = 1'b0;

    // Cycle-by-cycle equivalence check on the falling edge
    always @(negedge clk) begin
        if (checking) begin
            checks++;
            if (u_ops_t !== r_ops_t || u_opsv_t !== r_opsv_t ||
                u_ops_b !== r_ops_b || u_opsv_b !== r_opsv_b) begin
                errors++;
                $error("[FAIL] t=%0t psum mismatch: top uut %0d(V:%b) ref %0d(V:%b) | bot uut %0d(V:%b) ref %0d(V:%b)",
                       $time, u_ops_t, u_opsv_t, r_ops_t, r_opsv_t,
                              u_ops_b, u_opsv_b, r_ops_b, r_opsv_b);
            end
            if (u_oa_t !== r_oa_t || u_oav_t !== r_oav_t ||
                u_oa_b !== r_oa_b || u_oav_b !== r_oav_b) begin
                errors++;
                $error("[FAIL] t=%0t activation mismatch: top uut %0d(V:%b) ref %0d(V:%b) | bot uut %0d(V:%b) ref %0d(V:%b)",
                       $time, u_oa_t, u_oav_t, r_oa_t, r_oav_t,
                              u_oa_b, u_oav_b, r_oa_b, r_oav_b);
            end
            if (u_ow_t !== r_ow_t || u_owv_t !== r_owv_t ||
                u_ow_b !== r_ow_b || u_owv_b !== r_owv_b) begin
                errors++;
                $error("[FAIL] t=%0t weight mismatch: top uut %0d(V:%b) ref %0d(V:%b) | bot uut %0d(V:%b) ref %0d(V:%b)",
                       $time, u_ow_t, u_owv_t, r_ow_t, r_owv_t,
                              u_ow_b, u_owv_b, r_ow_b, r_owv_b);
            end
        end
    end

    // int8 values weighted toward the corner cases
    function automatic logic signed [7:0] rand_i8();
        case ($urandom_range(0, 5))
            0: rand_i8 = -8'sd128;
            1: rand_i8 = 8'sd127;
            2: rand_i8 = 8'sd0;
            default: rand_i8 = 8'($urandom);
        endcase
    endfunction

    function automatic logic signed [15:0] rand_i16();
        case ($urandom_range(0, 5))
            0: rand_i16 = -16'sd32768;
            1: rand_i16 = 16'sd32767;
            2: rand_i16 = 16'sd0;
            default: rand_i16 = 16'($urandom);
        endcase
    endfunction

    initial begin
        repeat (4) @(posedge clk);
        #1 reset = 1'b0;
        @(posedge clk);
        #1 checking = 1'b1;

        // Alternate randomized weight-loading bursts and compute bursts
        for (int phase = 0; phase < 80; phase++) begin
            // -- loading burst --
            @(posedge clk); #1;
            loading_phase = 1'b1;
            act_valid_t = 1'b0; act_valid_b = 1'b0; psum_valid_in = 1'b0;
            repeat ($urandom_range(2, 6)) begin
                capture_weight  = 1'($urandom);
                weight_in       = rand_i8();
                weight_valid_in = ($urandom_range(0, 3) != 0);
                @(posedge clk); #1;
            end
            loading_phase   = 1'b0;
            capture_weight  = 1'b0;
            weight_valid_in = 1'b0;
            weight_in       = '0;

            // -- compute burst --
            repeat ($urandom_range(8, 40)) begin
                act_t         = rand_i8();
                act_b         = rand_i8();
                act_valid_t   = ($urandom_range(0, 3) != 0);
                act_valid_b   = ($urandom_range(0, 3) != 0);
                psum_in       = rand_i16();
                psum_valid_in = ($urandom_range(0, 3) != 0);
                @(posedge clk); #1;
            end
            act_valid_t = 1'b0; act_valid_b = 1'b0; psum_valid_in = 1'b0;
            @(posedge clk); #1;
        end

        repeat (4) @(posedge clk);

        if (errors == 0) begin
            $display("\n==============================================");
            $display(">>> SUCCESS: PE_PAIR EQUIVALENCE PASSED <<<");
            $display(">>> %0d cycles compared bit-exact vs 2x pe.sv <<<", checks);
            $display("==============================================\n");
        end else begin
            $display("\n==============================================");
            $display(">>> FAILURE: %0d PE_PAIR MISMATCHES <<<", errors);
            $display("==============================================\n");
        end
        $finish;
    end

endmodule
