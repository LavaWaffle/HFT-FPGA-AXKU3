`timescale 1ns / 1ps
`default_nettype none

// Macros for decoding (Must match your system)
`define PRICE(x)  x[31:16]
`define IS_BUY(x) x[15]
`define IS_BOT(x) x[14]
`define QTY(x)    x[13:0]

`define TYPE_BID 1'b1 // Max Heap
`define TYPE_ASK 1'b0 // Min Heap

module front_runner_bot (
    input wire clk,
    input wire rst,
    input wire enable,              // External Enable Switch

    // --- Inputs from the Heap Managers (via Dot Syntax) ---
    input wire [31:0] bid_root,     // Current Best Bid
    input wire [31:0] ask_root,     // Current Best Ask
    
    // --- System Status ---
    input wire udp_fifo_has_data,   // High if UDP FIFO has data (Bot must yield)
    input wire engine_busy,         // High if Matching Engine is busy

    // --- I/O to Bot FIFO IN ---
    output reg        bot_valid,
    output reg [31:0] bot_data,      // {Price, Side, ID=1, Qty}
    input wire        bot_full       // High if Bot FIFO is full (Backpressure
);

    // State Machine
    localparam S_IDLE      = 0;
    localparam S_CHECK_BID = 1;
    localparam S_CHECK_ASK = 2;
    localparam S_SEND_CMD  = 3;
    localparam S_COOLDOWN  = 4;

    reg [2:0] state;
    reg [15:0] target_price;
    reg        target_side; // 1=Bid, 0=Ask

    // Default Bot Settings
    localparam BOT_ID  = 1'b1;
    localparam BOT_QTY = 14'd10; // Simple fixed quantity

    always @(posedge clk) begin

        if (rst) begin
            state <= S_IDLE;
            bot_valid <= 0;
            bot_data <= 0;
        end else begin
            // Default: Pulse valid for only one cycle
            bot_valid <= 0; 

            case (state)
                S_IDLE: begin
                    // Only run if Enabled, and not backpressured
                    if (enable && !bot_full && !engine_busy && !udp_fifo_has_data) begin
                        state <= S_CHECK_BID;
                    end
                end

                // ---------------------------------------------------------
                // STRATEGY: FRONT RUN BIDS
                // ---------------------------------------------------------
                S_CHECK_BID: begin
                    // If Heap is empty (root=0), don't place bid 
                    if (bid_root == 0) begin
                        state <= S_CHECK_ASK;
                    end
                    // If Top is NOT a Bot, Front Run it!
                    else if (`IS_BOT(bid_root) == 1'b0) begin
                        if (ask_root != 0 && ((`PRICE(bid_root) + 1) <= `PRICE(ask_root))) begin
                            target_price <= `PRICE(bid_root) + 1; // Price + 1
                            target_side  <= `TYPE_BID; // Bid
                            state <= S_SEND_CMD;
                        end else begin
                            state <= S_CHECK_ASK;
                        end
                        
                        
                    end 
                    // If Top IS a Bot, ignore and check Asks
                    else begin
                        state <= S_CHECK_ASK;
                    end
                end

                // ---------------------------------------------------------
                // STRATEGY: FRONT RUN ASKS
                // ---------------------------------------------------------
                S_CHECK_ASK: begin
                    // If Heap is empty, go to IDLE
                    if (ask_root == 0) begin
                        state <= S_IDLE;
                    end
                    // If Top is NOT a Bot, Front Run it!
                    else if (`IS_BOT(ask_root) == 1'b0) begin
                        // Don't underflow 0
                        if (`PRICE(ask_root) > 1) begin
                        
                            if (bid_root != 0 && ((`PRICE(ask_root) - 1) <= `PRICE(bid_root))) begin
                                state <= S_IDLE; // Spread too tight, skip Asking
                            end else begin
                                target_price <= `PRICE(ask_root) - 1;
                                target_side  <= `TYPE_ASK;
                                state <= S_SEND_CMD;
                            end
                        end else begin
                            state <= S_IDLE;
                        end
                    end 
                    // If Top IS a Bot, we are done
                    else begin
                        state <= S_IDLE;
                    end
                end

                // ---------------------------------------------------------
                // EXECUTE
                // ---------------------------------------------------------
                S_SEND_CMD: begin
                    // Re-check priority before firing
                    if (!udp_fifo_has_data && !engine_busy && !bot_full) begin
                        bot_data <= {target_price, target_side, BOT_ID, BOT_QTY};
                        bot_valid <= 1;
                        state <= S_COOLDOWN;
                    end else begin
                        // If UDP woke up, abort and wait
                        state <= S_IDLE;
                    end
                end

                // ---------------------------------------------------------
                // COOLDOWN
                // ---------------------------------------------------------
                S_COOLDOWN: begin
                    // Give the engine 1 cycle to assert "busy" so we don't spam
                    state <= S_IDLE;
                end

            endcase
        end
    end

endmodule