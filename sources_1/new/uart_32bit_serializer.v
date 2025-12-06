`timescale 1ns / 1ps
module uart_32bit_serializer (
    input  wire        clk,
    input  wire        rst,

    // Interface to 32-bit FIFO
    input  wire [31:0] fifo_data,
    input  wire        fifo_valid, // !empty
    output reg         fifo_rd_en,

    // Interface to 8-bit UART TX
    output reg  [7:0]  uart_data_out,
    output reg         uart_start,
    input  wire        uart_busy
);

    localparam S_IDLE      = 0;
    localparam S_READ_FIFO = 1;
    localparam S_SEND_B3   = 2; // Bits [31:24]
    localparam S_SEND_B2   = 3; // Bits [23:16]
    localparam S_SEND_B1   = 4; // Bits [15:8]
    localparam S_SEND_B0   = 5; // Bits [7:0]
    localparam S_WAIT_UART = 6;

    reg [2:0]  state;
    reg [2:0]  next_state_after_wait;
    reg [31:0] data_buffer;

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            fifo_rd_en <= 0;
            uart_start <= 0;
            uart_data_out <= 0;
            data_buffer <= 0;
        end else begin
            // Default Pulses
            fifo_rd_en <= 0;
            uart_start <= 0;

            case (state)
                S_IDLE: begin
                    // If FIFO has data, grab it
                    if (fifo_valid) begin
                        // For FWFT FIFO, data is ready now. 
                        // We pulse read to advance to NEXT data for next time.
                        data_buffer <= fifo_data;
                        fifo_rd_en  <= 1; 
                        state       <= S_SEND_B3;
                    end
                end

                // --- Byte 3 (MSB) ---
                S_SEND_B3: begin
                    if (!uart_busy) begin
                        uart_data_out <= data_buffer[31:24];
                        uart_start    <= 1;
                        next_state_after_wait <= S_SEND_B2;
                        state <= S_WAIT_UART;
                    end
                end

                // --- Byte 2 ---
                S_SEND_B2: begin
                    if (!uart_busy) begin
                        uart_data_out <= data_buffer[23:16];
                        uart_start    <= 1;
                        next_state_after_wait <= S_SEND_B1;
                        state <= S_WAIT_UART;
                    end
                end

                // --- Byte 1 ---
                S_SEND_B1: begin
                    if (!uart_busy) begin
                        uart_data_out <= data_buffer[15:8];
                        uart_start    <= 1;
                        next_state_after_wait <= S_SEND_B0;
                        state <= S_WAIT_UART;
                    end
                end

                // --- Byte 0 (LSB) ---
                S_SEND_B0: begin
                    if (!uart_busy) begin
                        uart_data_out <= data_buffer[7:0];
                        uart_start    <= 1;
                        next_state_after_wait <= S_IDLE;
                        state <= S_WAIT_UART;
                    end
                end

                // --- Wait for UART to accept command and become busy ---
                S_WAIT_UART: begin
                    // We need to wait for uart_busy to likely go HIGH then LOW, 
                    // or just ensure we don't send too fast.
                    // Simple check: if !uart_busy, we *might* be ready, 
                    // but we just pulsed start, so busy takes 1 cycle to assert.
                    state <= next_state_after_wait;
                end

            endcase
        end
    end
endmodule