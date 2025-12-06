`timescale 1ns / 1ps

module uart_payload_extractor(
    input  wire        clk,
    input  wire        rst,
    
    // Input Stream (RX from other party)
    input  wire [7:0]  uart_rx_data_out,
    input  wire        uart_rx_data_valid, // Pulse when data is ready
    
    // Output: Command Trigger (For Opcode FE00)
    output reg         trigger_dump
);
    
    // --- PARAMETERS & INTERNAL REGISTERS ---
    // Command is 16'hFE00
    localparam [15:0] OP_DUMP_BOOK = 16'hFE00;
    
    // Counter width: We only need to count 0, 1, 2 (2 bits wide is enough)
    // 0: Expecting first byte
    // 1: Expecting second byte
    // 2: Done/Error/Cleanup
    reg [1:0] byte_cnt; 
    reg       active_packet; // Tracks if we are in the middle of a command sequence
    reg       is_dump_cmd_first_byte; // Tracks if the first byte matched 0xFE
    
    // --- LOGIC ---
    always @(posedge clk) begin
        // --- Defaults ---
        // trigger_dump is a pulse, so it must default low
        trigger_dump <= 1'b0;
        
        if (rst) begin
            byte_cnt               <= 2'b00;
            active_packet          <= 1'b0;
            is_dump_cmd_first_byte <= 1'b0;
        end 
        // Only proceed if a valid byte has arrived
        else if (uart_rx_data_valid) begin
            
            // Increment the counter every time a byte is valid
            // If the counter is 0 and a byte arrived, we are starting the sequence.
            byte_cnt <= byte_cnt + 1;

            // Packet Start Condition:
            if (!active_packet) begin
                // The first byte received MUST be the first byte of the command
                active_packet          <= 1'b1;
                is_dump_cmd_first_byte <= 1'b0; // Reset tracking for this new sequence
                
                // If the very first byte matches the MSB of the command
                if (uart_rx_data_out == OP_DUMP_BOOK[15:8]) begin
                    is_dump_cmd_first_byte <= 1'b1;
                end
                
                // Set the counter to 1, since this is the first byte (byte_cnt was 0 previously)
                byte_cnt <= 1; 

            end
            
            // Payload Processing: Check for second byte when byte_cnt == 1 (after next clock cycle)
            else if (byte_cnt == 1) begin
                
                // Check if the previous byte matched 0xFE AND the current byte matches 0x00
                if (is_dump_cmd_first_byte && (uart_rx_data_out == OP_DUMP_BOOK[7:0])) begin
                    // FULL COMMAND MATCH! Pulse the trigger.
                    trigger_dump <= 1'b1;
                end
                
                // After checking the second byte, the two-byte command sequence is done.
                active_packet <= 1'b0;
                byte_cnt      <= 2'b00; // Reset counter for the next sequence start
                
            end
            
            // Handle bytes beyond the 2nd byte if your packet is longer (Cleanup/Flush)
            else begin
                 // For a simple 2-byte command extractor, any byte after the second byte 
                 // is either trailing data or an error, so we reset the sequence.
                 active_packet <= 1'b0;
                 byte_cnt      <= 2'b00;
            end
            
        end 
   
    end
endmodule


