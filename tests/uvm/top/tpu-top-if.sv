// tpu_top's pins: the Avalon-MM slave the host drives
interface tpu_top_if (input logic clk);
    logic        reset_n;
    logic [3:0]  avs_address;
    logic        avs_read;
    logic [31:0] avs_readdata;
    logic        avs_write;
    logic [31:0] avs_writedata;
    logic        avs_waitrequest;
endinterface
