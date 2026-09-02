// AMBA APB slave wrapper around ascon_aead_fsm. Implements the
// register map in docs/spec.md section 7. This is the synthesizable
// top-level IP: rtl/core/ does not know anything about the bus.
//
// APB two-phase handling: a register write only ever commits on a
// clock edge where psel && penable && pwrite are all 1 (the ACCESS
// phase) -- psel alone (SETUP phase) never has a side effect. This
// is a zero-wait-state slave (pready is always 1); pslverr is driven
// combinationally so it is valid in the same ACCESS cycle pready is
// sampled, per APB protocol.

module ascon_apb (
    input  wire        pclk,
    input  wire        presetn,

    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [7:0]  paddr,
    input  wire [31:0] pwdata,
    output reg  [31:0] prdata,
    output wire         pready,
    output wire         pslverr
);

    // opcode encoding (docs/spec.md 7.1) -- duplicated locally, same
    // convention as rtl/core/ascon_aead_fsm.v
    localparam OP_PROC_AD   = 3'd2;
    localparam OP_PROC_TEXT = 3'd3;

    // ---- register file ------------------------------------------------
    reg [127:0] key_r, nonce_r, din_r, tag_in_r;
    reg [127:0] dout_reg, tag_reg;
    reg [2:0]   din_count;

    reg         fsm_start;
    reg [2:0]   fsm_opcode;
    reg         fsm_last, fsm_mode;
    reg [4:0]   fsm_vbytes;

    reg         done_sticky, dout_valid_sticky, tag_valid_sticky;

    wire        fsm_busy, fsm_done, fsm_dout_valid, fsm_tag_valid, fsm_tag_fail;
    wire [127:0] fsm_dout, fsm_tag;

    ascon_aead_fsm u_fsm (
        .clk         (pclk),
        .rst_n       (presetn),
        .start       (fsm_start),
        .opcode      (fsm_opcode),
        .last        (fsm_last),
        .mode        (fsm_mode),
        .valid_bytes (fsm_vbytes),
        .key         (key_r),
        .nonce       (nonce_r),
        .din         (din_r),
        .tag_in      (tag_in_r),
        .busy        (fsm_busy),
        .done        (fsm_done),
        .dout        (fsm_dout),
        .dout_valid  (fsm_dout_valid),
        .tag         (fsm_tag),
        .tag_valid   (fsm_tag_valid),
        .tag_fail    (fsm_tag_fail)
    );

    wire din_full = (din_count >= 3'd4);

    // ---- write-transfer decode (ACCESS phase only) ---------------------
    wire cmd_write      = psel && penable && pwrite && (paddr == 8'h00);
    wire [2:0] cmd_op_w = pwdata[2:0];
    wire cmd_needs_din  = (cmd_op_w == OP_PROC_AD) || (cmd_op_w == OP_PROC_TEXT);

    // docs/spec.md 9.3: writing a processing command while din_full=0
    // is rejected with pslverr. A command write while the core is busy
    // is silently ignored (no error, no effect).
    assign pslverr = cmd_write && !fsm_busy && cmd_needs_din && !din_full;

    wire cmd_accept = cmd_write && !fsm_busy && (cmd_op_w != 3'd0) && !pslverr;

    assign pready = 1'b1; // zero-wait-state slave

    always @(posedge pclk or negedge presetn) begin
        if (!presetn) begin
            key_r     <= 128'h0;
            nonce_r   <= 128'h0;
            din_r     <= 128'h0;
            tag_in_r  <= 128'h0;
            din_count <= 3'd0;

            fsm_start  <= 1'b0;
            fsm_opcode <= 3'd0;
            fsm_last   <= 1'b0;
            fsm_mode   <= 1'b0;
            fsm_vbytes <= 5'd0;

            done_sticky       <= 1'b0;
            dout_valid_sticky <= 1'b0;
            tag_valid_sticky  <= 1'b0;
            dout_reg <= 128'h0;
            tag_reg  <= 128'h0;
        end else begin
            fsm_start <= 1'b0; // default: single-cycle pulse

            // capture FSM completion pulses first so a command write
            // accepted in this same cycle (see below) always wins the
            // "clear on new command" race against a same-cycle done
            // pulse from the operation that just finished.
            if (fsm_done)
                done_sticky <= 1'b1;
            if (fsm_dout_valid) begin
                dout_reg          <= fsm_dout;
                dout_valid_sticky <= 1'b1;
            end
            if (fsm_tag_valid) begin
                tag_reg          <= fsm_tag;
                tag_valid_sticky <= 1'b1;
            end

            if (psel && penable && pwrite && pready) begin
                case (paddr)
                    8'h00: begin // CMD
                        if (cmd_accept) begin
                            fsm_opcode <= cmd_op_w;
                            fsm_last   <= pwdata[3];
                            fsm_mode   <= pwdata[4];
                            fsm_vbytes <= pwdata[12:8];
                            fsm_start  <= 1'b1;

                            done_sticky       <= 1'b0;
                            dout_valid_sticky <= 1'b0;
                            tag_valid_sticky  <= 1'b0;
                            din_count         <= 3'd0;
                        end
                    end

                    8'h10: key_r[31:0]     <= pwdata;
                    8'h14: key_r[63:32]    <= pwdata;
                    8'h18: key_r[95:64]    <= pwdata;
                    8'h1C: key_r[127:96]   <= pwdata;

                    8'h20: nonce_r[31:0]   <= pwdata;
                    8'h24: nonce_r[63:32]  <= pwdata;
                    8'h28: nonce_r[95:64]  <= pwdata;
                    8'h2C: nonce_r[127:96] <= pwdata;

                    8'h30: begin din_r[31:0]   <= pwdata; din_count <= din_count + 3'd1; end
                    8'h34: begin din_r[63:32]  <= pwdata; din_count <= din_count + 3'd1; end
                    8'h38: begin din_r[95:64]  <= pwdata; din_count <= din_count + 3'd1; end
                    8'h3C: begin din_r[127:96] <= pwdata; din_count <= din_count + 3'd1; end

                    8'h60: tag_in_r[31:0]   <= pwdata;
                    8'h64: tag_in_r[63:32]  <= pwdata;
                    8'h68: tag_in_r[95:64]  <= pwdata;
                    8'h6C: tag_in_r[127:96] <= pwdata;

                    default: ; // STATUS/DOUT/TAG (read-only) or unmapped: ignore
                endcase
            end
        end
    end

    // ---- read mux (address-decoded, no side effects) -------------------
    wire [31:0] status_word = { 26'h0, din_full, fsm_tag_fail,
                                 tag_valid_sticky, dout_valid_sticky,
                                 done_sticky, fsm_busy };

    always @(*) begin
        prdata = 32'h0; // default -- also covers CMD/KEY/NONCE/DIN/TAGIN
                         // and any unmapped address (KEY: "chi ghi, doc
                         // tra ve 0" per docs/spec.md 7)
        case (paddr)
            8'h04: prdata = status_word;
            8'h40: prdata = dout_reg[31:0];
            8'h44: prdata = dout_reg[63:32];
            8'h48: prdata = dout_reg[95:64];
            8'h4C: prdata = dout_reg[127:96];
            8'h50: prdata = tag_reg[31:0];
            8'h54: prdata = tag_reg[63:32];
            8'h58: prdata = tag_reg[95:64];
            8'h5C: prdata = tag_reg[127:96];
            default: prdata = 32'h0;
        endcase
    end

endmodule
