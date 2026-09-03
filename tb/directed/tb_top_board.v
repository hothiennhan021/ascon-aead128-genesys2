// Directed testbench for rtl/demo/top_board.v: a host-side UART BFM
// (this file plays the role of scripts/uart_kat.py) drives a couple
// of NIST KAT vectors through the full board -- USB-UART bridge sim
// -> uart_rx -> cmd_fsm -> apb_master -> rtl/ip/ascon_apb.v ->
// rtl/core/ascon_aead_fsm.v -- and checks the ciphertext/tag that
// come back over "UART", plus the LED status bits.
//
// Built with -DSIM_NO_MMCM: top_board.v then bypasses IBUFDS/
// MMCME2_BASE (Xilinx UNISIM primitives with no Icarus model) and
// feeds sysclk_p straight through as the system clock -- see
// top_board.v's header comment. CLK_FREQ_HZ is also overridden way
// down from the real 100 MHz so the simulated UART bit period is
// short; this only changes how many clock cycles make up one UART
// bit; the protocol, framing and APB/core behaviour being exercised
// are exactly the real ones.

`timescale 1ns/1ps

module tb_top_board;

    // ---- scaled-down clock/UART timing for simulation -------------------
    localparam CLK_FREQ_HZ_TB = 1_000_000; // 1 MHz "system clock" stand-in
    localparam BAUD           = 115200;    // must match top_board.v's default
    localparam CLK_PERIOD_NS  = 1_000_000_000 / CLK_FREQ_HZ_TB;
    localparam CYCLES_PER_BIT = CLK_FREQ_HZ_TB / BAUD;
    localparam BIT_PERIOD_NS  = CYCLES_PER_BIT * CLK_PERIOD_NS;

    // ---- protocol / register map constants (docs/spec.md 7) -------------
    localparam [7:0] OP_WRITE       = 8'h01;
    localparam [7:0] OP_READ        = 8'h02;
    localparam [7:0] OP_READ_STATUS = 8'h03;

    localparam [7:0] OP_INIT      = 8'h01; // CMD opcode field, not UART opcode
    localparam [7:0] OP_PROC_AD   = 8'h02;
    localparam [7:0] OP_PROC_TEXT = 8'h03;
    localparam [7:0] OP_FINAL     = 8'h04;

    localparam [7:0] ADDR_CMD    = 8'h00;
    localparam [7:0] ADDR_STATUS = 8'h04;
    localparam [7:0] ADDR_KEY0   = 8'h10;
    localparam [7:0] ADDR_NONCE0 = 8'h20;
    localparam [7:0] ADDR_DIN0   = 8'h30;
    localparam [7:0] ADDR_DOUT0  = 8'h40;
    localparam [7:0] ADDR_TAG0   = 8'h50;

    // ---- DUT hookup -------------------------------------------------------
    reg        sysclk_p_r;
    wire       sysclk_n_w = ~sysclk_p_r;
    reg        btnc_r;
    reg        uart_rx_out_r; // host TX -> DUT RX
    wire       uart_tx_in_w;  // DUT TX -> host RX
    wire [7:0] led_w;

    top_board #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ_TB)
    ) dut (
        .sysclk_p    (sysclk_p_r),
        .sysclk_n    (sysclk_n_w),
        .btnc        (btnc_r),
        .uart_rx_out (uart_rx_out_r),
        .uart_tx_in  (uart_tx_in_w),
        .led         (led_w)
    );

    initial sysclk_p_r = 1'b0;
    always #(CLK_PERIOD_NS/2) sysclk_p_r = ~sysclk_p_r;

    // ---- global watchdog: any hang fails the run instead of stalling ----
    initial begin
        #200_000_000; // 200 ms sim time -- generous vs. the ~tens of us
                       // a full vector actually takes at this baud
        $display("FAIL WATCHDOG TIMEOUT -- simulation hung");
        $finish;
    end

    // ---- host-side UART BFM (this IS the "USB-UART bridge + PC" side) --
    task host_send_byte;
        input [7:0] b;
        integer i;
        begin
            uart_rx_out_r = 1'b0; // start bit
            #BIT_PERIOD_NS;
            for (i = 0; i < 8; i = i + 1) begin
                uart_rx_out_r = b[i];
                #BIT_PERIOD_NS;
            end
            uart_rx_out_r = 1'b1; // stop bit
            #BIT_PERIOD_NS;
        end
    endtask

    task host_recv_byte;
        output [7:0] b;
        integer i;
        begin
            @(negedge uart_tx_in_w); // start bit begins
            #(BIT_PERIOD_NS + BIT_PERIOD_NS/2); // land mid data-bit-0
            for (i = 0; i < 8; i = i + 1) begin
                b[i] = uart_tx_in_w;
                #BIT_PERIOD_NS;
            end
            // now mid stop-bit; nothing further needed
        end
    endtask

    // ---- protocol-level helpers -------------------------------------------
    reg [31:0] rd32;

    task uart_write_reg;
        input [7:0]  addr;
        input [31:0] data;
        begin
            host_send_byte(OP_WRITE);
            host_send_byte(addr);
            host_send_byte(data[7:0]);
            host_send_byte(data[15:8]);
            host_send_byte(data[23:16]);
            host_send_byte(data[31:24]);
        end
    endtask

    task uart_read_reg;
        input  [7:0]  addr;
        output [31:0] data;
        reg [7:0] b0, b1, b2, b3;
        begin
            host_send_byte(OP_READ);
            host_send_byte(addr);
            host_recv_byte(b0);
            host_recv_byte(b1);
            host_recv_byte(b2);
            host_recv_byte(b3);
            data = {b3, b2, b1, b0};
        end
    endtask

    task uart_read_status;
        output [31:0] data;
        reg [7:0] b0, b1, b2, b3;
        begin
            host_send_byte(OP_READ_STATUS);
            host_recv_byte(b0);
            host_recv_byte(b1);
            host_recv_byte(b2);
            host_recv_byte(b3);
            data = {b3, b2, b1, b0};
        end
    endtask

    task uart_wait_done;
        output [31:0] status;
        begin
            status = 32'h0;
            while (!status[1])
                uart_read_status(status);
        end
    endtask

    function [31:0] build_cmd;
        input [2:0] op;
        input       lst;
        input       md;
        input [4:0] vb;
        reg [31:0] w;
        begin
            w = 32'h0;
            w[2:0]  = op;
            w[3]    = lst;
            w[4]    = md;
            w[12:8] = vb;
            build_cmd = w;
        end
    endfunction

    task write_key_nonce_uart;
        input [127:0] key_v;
        input [127:0] nonce_v;
        begin
            uart_write_reg(ADDR_KEY0+8'h00, key_v[31:0]);
            uart_write_reg(ADDR_KEY0+8'h04, key_v[63:32]);
            uart_write_reg(ADDR_KEY0+8'h08, key_v[95:64]);
            uart_write_reg(ADDR_KEY0+8'h0C, key_v[127:96]);
            uart_write_reg(ADDR_NONCE0+8'h00, nonce_v[31:0]);
            uart_write_reg(ADDR_NONCE0+8'h04, nonce_v[63:32]);
            uart_write_reg(ADDR_NONCE0+8'h08, nonce_v[95:64]);
            uart_write_reg(ADDR_NONCE0+8'h0C, nonce_v[127:96]);
        end
    endtask

    task write_din_uart;
        input [127:0] d;
        begin
            uart_write_reg(ADDR_DIN0+8'h00, d[31:0]);
            uart_write_reg(ADDR_DIN0+8'h04, d[63:32]);
            uart_write_reg(ADDR_DIN0+8'h08, d[95:64]);
            uart_write_reg(ADDR_DIN0+8'h0C, d[127:96]);
        end
    endtask

    task read_dout_uart;
        output [127:0] d;
        begin
            uart_read_reg(ADDR_DOUT0+8'h00, rd32); d[31:0]   = rd32;
            uart_read_reg(ADDR_DOUT0+8'h04, rd32); d[63:32]  = rd32;
            uart_read_reg(ADDR_DOUT0+8'h08, rd32); d[95:64]  = rd32;
            uart_read_reg(ADDR_DOUT0+8'h0C, rd32); d[127:96] = rd32;
        end
    endtask

    task read_tag_uart;
        output [127:0] d;
        begin
            uart_read_reg(ADDR_TAG0+8'h00, rd32); d[31:0]   = rd32;
            uart_read_reg(ADDR_TAG0+8'h04, rd32); d[63:32]  = rd32;
            uart_read_reg(ADDR_TAG0+8'h08, rd32); d[95:64]  = rd32;
            uart_read_reg(ADDR_TAG0+8'h0C, rd32); d[127:96] = rd32;
        end
    endtask

    // ---- KAT vector memory (same layout/file as tb/directed/tb_apb.v) --
    // Full N_VEC=1089 range declared (matching tb_apb.v exactly) even
    // though this testbench only exercises 2 of them, so $readmemh
    // loads the whole kat_128_128.hex file without truncation.
    localparam VEC_WORDS = 41;
    localparam N_VEC     = 1089;
    reg [63:0] mem [0:VEC_WORDS*N_VEC-1];

    function [127:0] byte_mask;
        input [4:0] vbytes;
        integer k;
        reg [127:0] m;
        begin
            m = 128'h0;
            for (k = 0; k < 16; k = k + 1)
                if (k < vbytes) m[8*k +: 8] = 8'hFF;
            byte_mask = m;
        end
    endfunction

    integer errors, vec_pass;
    integer base, j;
    integer n_ad, n_pt;
    reg [127:0] key_v, nonce_v, din_v, exp_ct, exp_tag, captured_dout, captured_tag;
    reg [31:0]  status_word;
    reg [4:0]   vb;
    reg         vector_failed;

    task run_vector_uart;
        input integer v;
        begin
            base    = v * VEC_WORDS;
            key_v   = { mem[base+2], mem[base+1] };
            nonce_v = { mem[base+4], mem[base+3] };
            n_ad    = mem[base+5];
            n_pt    = mem[base+6];
            vector_failed = 1'b0;

            write_key_nonce_uart(key_v, nonce_v);
            uart_write_reg(ADDR_CMD, build_cmd(OP_INIT, 1'b0, 1'b0, 5'd0));
            uart_wait_done(status_word);

            for (j = 0; j < n_ad; j = j + 1) begin
                write_din_uart({ mem[base+9+j*4+1], mem[base+9+j*4+0] });
                uart_write_reg(ADDR_CMD, build_cmd(OP_PROC_AD,
                                                    mem[base+9+j*4+2][0],
                                                    1'b0,
                                                    mem[base+9+j*4+3][4:0]));
                uart_wait_done(status_word);
            end

            for (j = 0; j < n_pt; j = j + 1) begin
                vb = mem[base+21+j*4+3][4:0];
                write_din_uart({ mem[base+21+j*4+1], mem[base+21+j*4+0] });
                uart_write_reg(ADDR_CMD, build_cmd(OP_PROC_TEXT,
                                                    mem[base+21+j*4+2][0],
                                                    1'b0,
                                                    vb));
                uart_wait_done(status_word);

                if (status_word[2]) begin
                    read_dout_uart(captured_dout);
                    exp_ct = { mem[base+34+j*2], mem[base+33+j*2] };
                    if ((captured_dout & byte_mask(vb)) !== (exp_ct & byte_mask(vb)))
                        vector_failed = 1'b1;
                end else begin
                    vector_failed = 1'b1;
                end
            end

            uart_write_reg(ADDR_CMD, build_cmd(OP_FINAL, 1'b0, 1'b0, 5'd0));
            uart_wait_done(status_word);
            if (status_word[3]) begin
                read_tag_uart(captured_tag);
                exp_tag = { mem[base+40], mem[base+39] };
                if (captured_tag !== exp_tag)
                    vector_failed = 1'b1;
            end else begin
                vector_failed = 1'b1;
            end

            // LED check: done (bit1) must be reflected on led[1], and
            // tag_fail (bit4, always 0 here -- encrypt only) on led[7].
            if (led_w[1] !== status_word[1] || led_w[7] !== status_word[4])
                vector_failed = 1'b1;

            if (vector_failed) begin
                errors = errors + 1;
                $display("FAIL uart vector Count=%0d", mem[base+0]);
            end else begin
                vec_pass = vec_pass + 1;
                $display("PASS uart vector Count=%0d", mem[base+0]);
            end
        end
    endtask

    initial begin
        $readmemh("tb/directed/kat_128_128.hex", mem);

        errors   = 0;
        vec_pass = 0;

        uart_rx_out_r = 1'b1; // UART idle level
        btnc_r        = 1'b1; // hold board reset (BTNC) at power-up

        repeat (5) @(posedge sysclk_p_r);
        btnc_r = 1'b0; // release reset
        repeat (5) @(posedge sysclk_p_r);

        // vec 0: empty AD, empty PT (mandatory empty PROC_TEXT block)
        run_vector_uart(0);
        // vec 165: empty AD, 5-byte PT (real data, sub-block padding)
        run_vector_uart(165);

        $display("PASSED uart_top_board %0d/2", vec_pass);

        if (errors == 0 && vec_pass == 2)
            $display("PASSED ALL");
        else
            $display("FAILED (see FAIL lines above)");

        $finish;
    end

endmodule
