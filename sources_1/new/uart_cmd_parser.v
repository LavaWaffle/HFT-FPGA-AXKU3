`timescale 1ns / 1ps
`default_nettype none

module uart_cmd_parser (
    input  wire       clk,
    input  wire       rst,
    
    // UART RX Interface
    input  wire [7:0] rx_data,
    input  wire       rx_valid,
    
    // Trigger Output
    output reg        trigger_dump
);

    // Detect Sequence: F0 -> E0 -> D0
    localparam S_WAIT_F0 = 0;
    localparam S_WAIT_E0 = 1;
    localparam S_WAIT_D0 = 2;

    reg [1:0] state;

    always @(posedge clk) begin
        if (rst) begin
            state        <= S_WAIT_F0;
            trigger_dump <= 0;
        end else begin
            trigger_dump <= 0; // Pulse

            if (rx_valid) begin
                case (state)
                    S_WAIT_F0: begin
                        if (rx_data == 8'hF0) state <= S_WAIT_E0;
                    end
                    
                    S_WAIT_E0: begin
                        if (rx_data == 8'hE0) state <= S_WAIT_D0;
                        else if (rx_data == 8'hF0) state <= S_WAIT_E0; // Handle F0 F0 E0...
                        else state <= S_WAIT_F0;
                    end

                    S_WAIT_D0: begin
                        if (rx_data == 8'hD0) begin
                            trigger_dump <= 1; // FIRE!
                            state <= S_WAIT_F0;
                        end else if (rx_data == 8'hF0) begin
                             state <= S_WAIT_E0;
                        end else begin
                             state <= S_WAIT_F0;
                        end
                    end
                endcase
            end
        end
    end
endmodule