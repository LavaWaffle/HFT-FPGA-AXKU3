`timescale 1ns / 1ps
`default_nettype none

module uart_tx #(
    parameter CLK_FREQ  = 125_000_000, // System Clock Frequency
    parameter BAUD_RATE = 115200       // Desired Baud Rate
)(
    input  wire       clk,
    input  wire       rst,
    
    // User Interface
    input  wire [7:0] data_in,
    input  wire       tx_start,   // Valid signal for input data
    output reg        tx_busy,    // High while transmitting
    
    // Physical Interface
    output reg        uart_tx     // Connect to FPGA Pin
);

    // Calculate bit period
    localparam CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;
    
    // State Machine
    localparam S_IDLE  = 0;
    localparam S_START = 1;
    localparam S_DATA  = 2;
    localparam S_STOP  = 3;
    
    reg [2:0] state = S_IDLE;
    reg [13:0] clk_cnt;
    reg [2:0]  bit_idx;
    reg [7:0]  tx_shift;

    always @(posedge clk) begin
        if (rst) begin
            state       <= S_IDLE;
            uart_tx     <= 1'b1; // UART Idle is High
            tx_busy     <= 1'b0;
            clk_cnt     <= 0;
            bit_idx     <= 0;
            tx_shift    <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    uart_tx <= 1'b1;
                    clk_cnt <= 0;
                    bit_idx <= 0;
                    
                    if (tx_start) begin
                        tx_busy  <= 1'b1;
                        tx_shift <= data_in;
                        state    <= S_START;
                    end else begin
                        tx_busy <= 1'b0;
                    end
                end
                
                // Start Bit (Low)
                S_START: begin
                    uart_tx <= 1'b0;
                    if (clk_cnt < CLKS_PER_BIT - 1) begin
                        clk_cnt <= clk_cnt + 1;
                    end else begin
                        clk_cnt <= 0;
                        state   <= S_DATA;
                    end
                end
                
                // Data Bits (LSB First)
                S_DATA: begin
                    uart_tx <= tx_shift[bit_idx];
                    if (clk_cnt < CLKS_PER_BIT - 1) begin
                        clk_cnt <= clk_cnt + 1;
                    end else begin
                        clk_cnt <= 0;
                        if (bit_idx < 7) begin
                            bit_idx <= bit_idx + 1;
                        end else begin
                            bit_idx <= 0;
                            state   <= S_STOP;
                        end
                    end
                end
                
                // Stop Bit (High)
                S_STOP: begin
                    uart_tx <= 1'b1;
                    if (clk_cnt < CLKS_PER_BIT - 1) begin
                        clk_cnt <= clk_cnt + 1;
                    end else begin
                        clk_cnt <= 0;
                        // We are done. Go to IDLE.
                        // Busy will drop in IDLE state on next cycle.
                        state   <= S_IDLE;
                    end
                end
            endcase
        end
    end

endmodule