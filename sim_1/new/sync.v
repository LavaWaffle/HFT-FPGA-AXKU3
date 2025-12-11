`ifdef SYNTHESIS // Use big counter for synthesis
localparam COUNTER_WIDTH = 15; 
`else
localparam COUNTER_WIDTH = 1;
`endif

// synchronizer w/ debouncer (use for fpga buttons)
module sync_debounce (
    input  wire clk, 
    input  wire d, 

    output reg q
);

    reg ff1, ff2;
    reg [COUNTER_WIDTH : 0] counter;
    

    always @(posedge clk) begin
        ff1 <= d;   // flop input once
        ff2 <= ff1; // flop input twice

        // Change button only when 2^(COUNTER_WIDTH) stable input cycles are recorded 
        if (~(ff1 ^ ff2)) begin // detect an input difference per clock cycle
          if (~counter[COUNTER_WIDTH]) begin
              counter <= counter + 1'b1; // waiting for input to become stable
          end else begin
              q <= ff2; // input is idle
          end
        end else begin
           counter <= 0; // reset counter when bounce detected
        end
    end

endmodule

// basic double flop synchronizer (use for fgpa switches)
module sync_flop (
    input wire clk, 
    input wire d, 

    output reg q
);

    reg ff;

    always @(posedge clk) begin
        ff <= d;  // first flop
        q  <= ff; // second flop
    end

endmodule