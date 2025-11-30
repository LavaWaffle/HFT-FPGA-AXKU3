`include "order_defines.v"

module matching_engine (
    input wire clk,
    input wire rst_n,

    // --- Input from UDP/Strategy ---
    input wire input_valid,
    input wire input_is_buy,
    input wire [31:0] input_data, // {Price, ID, Qty}
    output reg engine_busy,

    // --- Interface to Bid Heap (Max Heap) ---
    input wire [31:0] bid_root,    // Best Bid Price/Qty
    input wire bid_empty,
    input wire bid_done,           // Ack from heap
    output reg [1:0] bid_cmd,
    output reg [31:0] bid_data_out,

    // --- Interface to Ask Heap (Min Heap) ---
    input wire [31:0] ask_root,    // Best Ask Price/Qty
    input wire ask_empty,
    input wire ask_done,
    output reg [1:0] ask_cmd,
    output reg [31:0] ask_data_out,

    // --- Trade Reporting ---
    output reg trade_valid,
    output reg [31:0] trade_info   // For debugging/logging
);

    // Internal State
    reg [3:0] state;
    localparam IDLE         = 0;
    localparam CHECK_MATCH  = 1; // Look at opposite book
    localparam EXEC_POP     = 2; // We eat the whole order
    localparam EXEC_UPDATE  = 3; // We eat part of the order
    localparam WAIT_HEAP    = 4; // Wait for Heap to finish POP/UPDATE
    localparam PLACE_ORDER  = 5; // Put remainder in our book
    localparam DONE         = 6;

    // Registers to hold the "Active Order" (The attacker)
    reg [15:0] my_price;
    reg [14:0] my_qty;
    reg my_is_buy;
    reg my_id;

    // Helper logic to see "Their" best price/qty
    reg [31:0] opp_root;
    reg [15:0] opp_price;
    reg [14:0] opp_qty;
    reg opp_empty;

    // --------------------------------------------------------
    // Mux logic to select the "Opposite" book
    // --------------------------------------------------------
    always @(*) begin
        // If I am buying, my "Opponent" is the Ask Heap.
        if (my_is_buy) begin
            opp_root = ask_root;
            opp_empty = ask_empty;
        end else begin
            opp_root = bid_root;
            opp_empty = bid_empty;
        end
        
        // Break out fields for easy math
        opp_price = `PRICE(opp_root);
        opp_qty   = `QTY(opp_root);
    end

    // --------------------------------------------------------
    // Main FSM
    // --------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            engine_busy <= 0;
            bid_cmd <= `CMD_NOP;
            ask_cmd <= `CMD_NOP;
            trade_valid <= 0;
        end else begin
            case (state)
                IDLE: begin
                    trade_valid <= 0;
                    bid_cmd <= `CMD_NOP;
                    ask_cmd <= `CMD_NOP;
                    
                    if (input_valid) begin
                        engine_busy <= 1;
                        // Latch the incoming order
                        my_is_buy <= input_is_buy;
                        my_price  <= `PRICE(input_data);
                        my_qty    <= `QTY(input_data);
                        my_id     <= `IS_BOT(input_data); // unused in matching, passed through
                        
                        state <= CHECK_MATCH;
                    end else begin
                        engine_busy <= 0;
                    end
                end

                CHECK_MATCH: begin
                    // 1. Is the opposite book empty?
                    if (opp_empty) begin
                        state <= PLACE_ORDER;
                    end
                    // 2. Does price cross?
                    // BUY: My Price >= Ask Price
                    // SELL: My Price <= Bid Price
                    else if ((my_is_buy && my_price >= opp_price) || 
                             (!my_is_buy && my_price <= opp_price)) begin
                        
                        // MATCH FOUND! Check Quantity logic.
                        if (my_qty >= opp_qty) begin
                            // Case A: We consume the entire resting order
                            state <= EXEC_POP;
                        end else begin
                            // Case B: We are smaller than the resting order
                            state <= EXEC_UPDATE;
                        end
                        
                    end else begin
                        // Price does not cross. We must rest.
                        state <= PLACE_ORDER;
                    end
                end

                EXEC_POP: begin
                    // Command the opposite heap to POP (remove root)
                    if (my_is_buy) ask_cmd <= `CMD_POP;
                    else           bid_cmd <= `CMD_POP;

                    // Generate Trade Report (Size = Their Qty)
                    trade_valid <= 1;
                    trade_info  <= {opp_price, 1'b0, opp_qty}; // {Price, ID, Qty}

                    // Update my remaining quantity
                    my_qty <= my_qty - opp_qty;

                    state <= WAIT_HEAP;
                end

                EXEC_UPDATE: begin
                    // Command opposite heap to modify quantity
                    // We need to send the NEW quantity (Their Qty - My Qty)
                    if (my_is_buy) begin
                        ask_cmd <= `CMD_UPDATE;
                        // Construct the data packet for the update
                        ask_data_out <= {opp_price, `IS_BOT(opp_root), (opp_qty - my_qty)};
                    end else begin
                        bid_cmd <= `CMD_UPDATE;
                        bid_data_out <= {opp_price, `IS_BOT(opp_root), (opp_qty - my_qty)};
                    end

                    // Generate Trade Report (Size = My Qty)
                    trade_valid <= 1;
                    trade_info  <= {opp_price, 1'b0, my_qty};

                    // I am fully filled.
                    my_qty <= 0;

                    state <= WAIT_HEAP;
                end

                WAIT_HEAP: begin
                    trade_valid <= 0;
                    bid_cmd <= `CMD_NOP;
                    ask_cmd <= `CMD_NOP;

                    // Wait for the specific heap to finish its job
                    if (my_is_buy) begin
                        if (ask_done) begin
                            // If I still have qty, go back and match more
                            if (my_qty > 0) state <= CHECK_MATCH;
                            else            state <= DONE;
                        end
                    end else begin
                        if (bid_done) begin
                            if (my_qty > 0) state <= CHECK_MATCH;
                            else            state <= DONE;
                        end
                    end
                end

                PLACE_ORDER: begin
                    // If we are here, we have remaining quantity to rest in book
                    if (my_qty > 0) begin
                        if (my_is_buy) begin
                            bid_cmd <= `CMD_PUSH;
                            bid_data_out <= {my_price, my_id, my_qty};
                            if (bid_done) state <= DONE; // wait for done ack?
                            // Simplified: Assume we hold CMD for 1 cycle then wait
                            // Better FSM would wait for 'bid_done' here similar to WAIT_HEAP
                        end else begin
                            ask_cmd <= `CMD_PUSH;
                            ask_data_out <= {my_price, my_id, my_qty};
                        end
                        state <= WAIT_HEAP; // Re-use wait state to wait for PUSH to finish
                        
                        // Special case: When pushing, we are placing into OUR book.
                        // So we need to tweak WAIT_HEAP logic slightly or just duplicate logic:
                        // Let's jump to a dedicated WAIT_PUSH to be clean.
                        state <= 7; // WAIT_PUSH
                    end else begin
                        state <= DONE;
                    end
                end
                
                7: begin // WAIT_PUSH
                     bid_cmd <= `CMD_NOP;
                     ask_cmd <= `CMD_NOP;
                     if (my_is_buy && bid_done) state <= DONE;
                     else if (!my_is_buy && ask_done) state <= DONE;
                end

                DONE: begin
                    engine_busy <= 0;
                    state <= IDLE;
                end

            endcase
        end
    end

endmodule