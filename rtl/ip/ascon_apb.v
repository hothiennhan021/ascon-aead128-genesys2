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
//
// Command checking (docs/spec.md 9.3, 9.6): a CMD write while the core
// is busy is silently ignored. Otherwise a command is rejected with
// pslverr (and STATUS.cmd_err) when
//   - the opcode is reserved (5, 6),
//   - PROC_AD/PROC_TEXT is issued before all four DIN words are written,
//   - PROC_AD/PROC_TEXT has last=1 with valid_bytes > 15,
//   - it breaks the session order INIT -> PROC_AD* -> PROC_TEXT+ -> FINAL,
//   - its mode bit differs from the mode chosen by INIT.
// KEY/NONCE/TAGIN writes are ignored while busy (the core reads them
// live during the operation). DIN writes stay allowed while busy so the
// next block can be loaded while the current one is processed.

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
    localparam OP_NOP        = 3'd0;
    localparam OP_INIT       = 3'd1;
    localparam OP_PROC_AD    = 3'd2;
    localparam OP_PROC_TEXT  = 3'd3;
    localparam OP_FINAL      = 3'd4;
    localparam OP_SOFT_RESET = 3'd7;

    // session order tracker (docs/spec.md 9.6)
    localparam SEQ_NONE    = 3'd0; // no session: only INIT/SOFT_RESET
    localparam SEQ_READY   = 3'd1; // after INIT
    localparam SEQ_AD      = 3'd2; // AD in progress (last AD block not seen)
    localparam SEQ_AD_DONE = 3'd3; // last AD block absorbed
    localparam SEQ_PT      = 3'd4; // text in progress (last block not seen)
    localparam SEQ_PT_DONE = 3'd5; // last text block processed

    // ---- register file ------------------------------------------------
    reg [127:0] key_r, nonce_r, din_r, tag_in_r;
    reg [127:0] dout_reg, tag_reg;
    reg [3:0]   din_written;   // one bit per DIN word written since last command

    reg         fsm_start;
    reg [2:0]   fsm_opcode;
    reg         fsm_last, fsm_mode;
    reg [4:0]   fsm_vbytes;

    reg         done_sticky, dout_valid_sticky, tag_valid_sticky, cmd_err_sticky;
    reg [2:0]   seq_r;
    reg         session_mode_r;

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

    // all four DIN words written (not just four writes -- rewriting the
    // same word does not count twice)
    wire din_full = &din_written;

    // ---- write-transfer decode (ACCESS phase only) ---------------------
    wire bus_write      = psel && penable && pwrite;
    wire cmd_write      = bus_write && (paddr == 8'h00);
    wire [2:0] cmd_op_w = pwdata[2:0];
    wire       cmd_last = pwdata[3];
    wire       cmd_mode = pwdata[4];
    wire [4:0] cmd_vb   = pwdata[12:8];

    wire cmd_is_ad    = (cmd_op_w == OP_PROC_AD);
    wire cmd_is_text  = (cmd_op_w == OP_PROC_TEXT);
    wire cmd_needs_din = cmd_is_ad || cmd_is_text;
    wire cmd_reserved = (cmd_op_w == 3'd5) || (cmd_op_w == 3'd6);

    // valid_bytes is only meaningful on a last block and must be 0..15
    // there (a full 16-byte tail needs an extra padding block, spec 9.4)
    wire vb_bad = cmd_needs_din && cmd_last && cmd_vb[4];

    reg order_ok;
    always @(*) begin
        order_ok = 1'b1;
        case (cmd_op_w)
            OP_PROC_AD:   order_ok = (seq_r == SEQ_READY) || (seq_r == SEQ_AD);
            OP_PROC_TEXT: order_ok = (seq_r == SEQ_READY) || (seq_r == SEQ_AD_DONE) ||
                                     (seq_r == SEQ_PT);
            OP_FINAL:     order_ok = (seq_r == SEQ_PT_DONE);
            default:      order_ok = 1'b1; // NOP, INIT, SOFT_RESET: always allowed
        endcase
    end

    wire mode_bad = (cmd_needs_din || (cmd_op_w == OP_FINAL)) &&
                    (cmd_mode != session_mode_r);

    wire cmd_reject = cmd_reserved || (cmd_needs_din && !din_full) || vb_bad ||
                      !order_ok || mode_bad;

    // docs/spec.md 9.3/9.6: rejected commands raise pslverr; a command
    // write while the core is busy is silently ignored (no error, no effect).
    assign pslverr = cmd_write && !fsm_busy && cmd_reject;

    wire cmd_accept = cmd_write && !fsm_busy && (cmd_op_w != OP_NOP) && !cmd_reject;

    assign pready = 1'b1; // zero-wait-state slave

    always @(posedge pclk or negedge presetn) begin
        if (!presetn) begin
            key_r       <= 128'h0;
            nonce_r     <= 128'h0;
            din_r       <= 128'h0;
            tag_in_r    <= 128'h0;
            din_written <= 4'b0000;

            fsm_start  <= 1'b0;
            fsm_opcode <= 3'd0;
            fsm_last   <= 1'b0;
            fsm_mode   <= 1'b0;
            fsm_vbytes <= 5'd0;

            done_sticky       <= 1'b0;
            dout_valid_sticky <= 1'b0;
            tag_valid_sticky  <= 1'b0;
            cmd_err_sticky    <= 1'b0;
            dout_reg <= 128'h0;
            tag_reg  <= 128'h0;

            seq_r          <= SEQ_NONE;
            session_mode_r <= 1'b0;
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

            if (pslverr)
                cmd_err_sticky <= 1'b1;

            if (bus_write && pready) begin
                case (paddr)
                    8'h00: begin // CMD
                        if (cmd_accept) begin
                            fsm_opcode <= cmd_op_w;
                            fsm_last   <= cmd_last;
                            fsm_mode   <= cmd_mode;
                            fsm_vbytes <= cmd_vb;
                            fsm_start  <= 1'b1;

                            done_sticky       <= 1'b0;
                            dout_valid_sticky <= 1'b0;
                            tag_valid_sticky  <= 1'b0;
                            cmd_err_sticky    <= 1'b0;
                            din_written       <= 4'b0000;

                            case (cmd_op_w)
                                OP_INIT: begin
                                    seq_r          <= SEQ_READY;
                                    session_mode_r <= cmd_mode;
                                    dout_reg       <= 128'h0;
                                    tag_reg        <= 128'h0;
                                end
                                OP_PROC_AD:
                                    seq_r <= cmd_last ? SEQ_AD_DONE : SEQ_AD;
                                OP_PROC_TEXT:
                                    seq_r <= cmd_last ? SEQ_PT_DONE : SEQ_PT;
                                OP_FINAL:
                                    seq_r <= SEQ_NONE;
                                OP_SOFT_RESET: begin
                                    seq_r          <= SEQ_NONE;
                                    session_mode_r <= 1'b0;
                                    din_r          <= 128'h0;
                                    tag_in_r       <= 128'h0;
                                    dout_reg       <= 128'h0;
                                    tag_reg        <= 128'h0;
                                end
                                default: ;
                            endcase
                        end
                    end

                    8'h10: if (!fsm_busy) key_r[31:0]     <= pwdata;
                    8'h14: if (!fsm_busy) key_r[63:32]    <= pwdata;
                    8'h18: if (!fsm_busy) key_r[95:64]    <= pwdata;
                    8'h1C: if (!fsm_busy) key_r[127:96]   <= pwdata;

                    8'h20: if (!fsm_busy) nonce_r[31:0]   <= pwdata;
                    8'h24: if (!fsm_busy) nonce_r[63:32]  <= pwdata;
                    8'h28: if (!fsm_busy) nonce_r[95:64]  <= pwdata;
                    8'h2C: if (!fsm_busy) nonce_r[127:96] <= pwdata;

                    8'h30: begin din_r[31:0]   <= pwdata; din_written[0] <= 1'b1; end
                    8'h34: begin din_r[63:32]  <= pwdata; din_written[1] <= 1'b1; end
                    8'h38: begin din_r[95:64]  <= pwdata; din_written[2] <= 1'b1; end
                    8'h3C: begin din_r[127:96] <= pwdata; din_written[3] <= 1'b1; end

                    8'h60: if (!fsm_busy) tag_in_r[31:0]   <= pwdata;
                    8'h64: if (!fsm_busy) tag_in_r[63:32]  <= pwdata;
                    8'h68: if (!fsm_busy) tag_in_r[95:64]  <= pwdata;
                    8'h6C: if (!fsm_busy) tag_in_r[127:96] <= pwdata;

                    default: ; // STATUS/DOUT/TAG (read-only) or unmapped: ignore
                endcase
            end
        end
    end

    // ---- read mux (address-decoded, no side effects) -------------------
    wire [31:0] status_word = { 25'h0, cmd_err_sticky, din_full, fsm_tag_fail,
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
