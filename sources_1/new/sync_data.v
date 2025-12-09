`timescale 1ns / 1ps
`default_nettype none

module sync_data #(
    parameter WIDTH = 1 
) (
    input  wire         src_clk,
    input  wire         src_rst, 
    input  wire [WIDTH-1:0] src_in,  
    
    input  wire         dest_clk,
    input  wire         dest_rst, 
    output wire [WIDTH-1:0] dest_out 
);

    localparam SYNC_STAGES = 2; 

    reg [WIDTH-1:0] sync_regs [0:SYNC_STAGES-1];

    always @(posedge dest_clk) begin
        if (dest_rst) begin
            sync_regs[0] <= 'b0;
            sync_regs[1] <= 'b0;
        end else begin
            sync_regs[0] <= src_in;
            sync_regs[1] <= sync_regs[0];
        end
    end
    
    assign dest_out = sync_regs[1];

endmodule