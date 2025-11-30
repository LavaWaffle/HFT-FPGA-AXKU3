`include "order_defines.v"

module simple_bram (
    input wire clk,
    input wire we,                   // Write Enable
    input wire [`ADDR_WIDTH-1:0] addr, 
    input wire [`DATA_WIDTH-1:0] wdata,
    output reg [`DATA_WIDTH-1:0] rdata
);

    // Declare the RAM array
    // 1024 depth, 32-bit width
    (* ram_style = "block" *)
    reg [`DATA_WIDTH-1:0] ram [0:(1<<`ADDR_WIDTH)-1];

    always @(posedge clk) begin
        if (we) begin
            ram[addr] <= wdata;
        end
        rdata <= ram[addr];
    end

endmodule