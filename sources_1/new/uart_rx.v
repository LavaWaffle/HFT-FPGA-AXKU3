`timescale 1ns / 1ps
`default_nettype none

module uart_rx #(
    parameter CLK_FREQ  = 125_000_000,
    parameter BAUD_RATE = 115200
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       uart_rx_in,
    
    output reg  [7:0] rx_data,
    output reg        rx_valid
);

    localparam CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;
    localparam HALF_BIT     = CLKS_PER_BIT / 2;

    localparam S_IDLE  = 0;
    localparam S_START = 1;
    localparam S_DATA  = 2;
    localparam S_STOP  = 3;

    reg [2:0] state = S_IDLE;
    reg [13:0] clk_cnt;
    reg [2:0]  bit_idx;
    reg [7:0]  rx_shift;
    
    // CDC Synchronizer for async RX input
    reg rx_sync_1, rx_sync;
    always @(posedge clk) begin
        rx_sync_1 <= uart_rx_in;
        rx_sync   <= rx_sync_1;
    end

    always @(posedge clk) begin
        if (rst) begin
            state    <= S_IDLE;
            rx_valid <= 0;
            rx_data  <= 0;
            clk_cnt  <= 0;
            bit_idx  <= 0;
        end else begin
            rx_valid <= 0; // Single cycle pulse

            case (state)
                S_IDLE: begin
                    clk_cnt <= 0;
                    bit_idx <= 0;
                    if (rx_sync == 0) begin // Start Bit Detected
                        state <= S_START;
                    end
                end

                // Verify Start Bit (Sample at middle)
                S_START: begin
                    if (clk_cnt == HALF_BIT) begin
                        if (rx_sync == 0) begin
                            clk_cnt <= 0;
                            state   <= S_DATA;
                        end else begin
                            state <= S_IDLE; // False start
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end

                // Read 8 Data Bits
                S_DATA: begin
                    if (clk_cnt == CLKS_PER_BIT) begin
                        clk_cnt <= 0;
                        rx_shift[bit_idx] <= rx_sync;
                        
                        if (bit_idx < 7) begin
                            bit_idx <= bit_idx + 1;
                        end else begin
                            bit_idx <= 0;
                            state   <= S_STOP;
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end

                // Stop Bit (Wait for high)
                S_STOP: begin
                    if (clk_cnt == CLKS_PER_BIT) begin
                        state    <= S_IDLE;
                        rx_valid <= 1;
                        rx_data  <= rx_shift;
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end
            endcase
        end
    end
endmodule