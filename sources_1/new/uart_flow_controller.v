`timescale 1ns / 1ps
module uart_flow_controller (
    input  wire       clk,
    input  wire       rst,

    // FIFO Interface (8-bit FWFT)
    input  wire       fifo_valid,   // !empty
    output reg        fifo_rd_en,

    // UART Interface
    output reg        uart_start,
    input  wire       uart_busy
);

    localparam S_IDLE      = 0;
    localparam S_FIRE      = 1;
    localparam S_WAIT_BUSY = 2;
    localparam S_WAIT_DONE = 3;

    reg [1:0] state;

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            fifo_rd_en <= 0;
            uart_start <= 0;
        end else begin
            // Default: Signals are pulses, so clear them every cycle
            fifo_rd_en <= 0;
            uart_start <= 0;

            case (state)
                S_IDLE: begin
                    // If FIFO has data AND UART is ready
                    if (fifo_valid && !uart_busy) begin
                        state <= S_FIRE;
                    end
                end

                S_FIRE: begin
                    // Fire both simultaneously
                    // 1. Tell UART to take the data CURRENTLY on the wire (FWFT)
                    uart_start <= 1;
                    // 2. Tell FIFO to pop that byte and prepare the next one
                    fifo_rd_en <= 1;
                    
                    state <= S_WAIT_BUSY;
                end

                S_WAIT_BUSY: begin
                    // Wait for UART to acknowledge the start by raising BUSY.
                    // This prevents us from firing again too quickly.
                    if (uart_busy) begin
                        state <= S_WAIT_DONE;
                    end
                end

                S_WAIT_DONE: begin
                    // Wait for UART to finish transmission
                    if (!uart_busy) begin
                        state <= S_IDLE;
                    end
                end
            endcase
        end
    end
endmodule