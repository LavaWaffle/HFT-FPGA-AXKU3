// -----------------------------------------------------------------------------
// uart_tx_handler: Manages the handshake for sending data out the UART PHY.
// -----------------------------------------------------------------------------
module uart_tx_handler (
    input  wire          clk,
    input  wire          rst,
    
    input  wire [7:0]    s_axis_tdata,
    input  wire          s_axis_tvalid,
    output wire          s_axis_tready, // Output AXI Stream Ready Signal
    
    input  wire          tx_byte_ready, // PHY Ready to take data
    output wire [7:0]    tx_byte_data,  // Data to PHY
    output reg           tx_byte_valid  // Asserted when sending data to PHY
);

    // State to track if we have a byte buffered and waiting for the PHY
    reg byte_buffered = 1'b0;
    reg [7:0] tx_data_fifo_reg = 8'h00; // Internal register holds data

    // Ready to accept stream input if:
    // 1. We don't have a byte buffered, OR
    // 2. We have a byte buffered AND the PHY is ready (and consuming it this cycle)
    // The latter case handles back-to-back transfer (pass-through).
    assign s_axis_tready = !byte_buffered | (byte_buffered & tx_byte_ready);

    // Continuous assignment: Data to PHY is always the buffered data.
    assign tx_byte_data = tx_data_fifo_reg;

    always @(posedge clk) begin
        // Defaults
        tx_byte_valid <= 1'b0;

        if (rst) begin
            byte_buffered <= 1'b0;
        end else begin
            // 1. Consumer (PHY) handshake:
            if (tx_byte_ready & byte_buffered) begin
                // The PHY is ready AND we have data to send: send it this cycle.
                tx_byte_valid <= 1'b1;
                // Since the byte is consumed, clear the buffer flag for the next cycle.
                byte_buffered <= 1'b0;
            end

            // 2. Producer (AXI Stream) handshake:
            if (s_axis_tvalid & s_axis_tready) begin
                // A new byte is being accepted from the AXI stream.
                tx_data_fifo_reg <= s_axis_tdata;
                
                // If the PHY didn't consume a byte this cycle, the new byte must be buffered.
                if (!(tx_byte_ready & byte_buffered)) begin
                    byte_buffered <= 1'b1;
                }
                // If the PHY DID consume a byte this cycle, then the new byte immediately replaces the old one,
                // and the buffered flag remains low (it's a passthrough).
            end
        end
    end

endmodule