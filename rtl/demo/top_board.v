// Top-level demo for Digilent Genesys 2 (xc7k325tffg900-2). Bridges
// the board's USB-UART to rtl/ip/ascon_apb.v so a host script
// (scripts/uart_kat.py) can drive the core over a serial port.
// rtl/demo/ only -- does not modify rtl/core/ or rtl/ip/.
//
// Clocking: Genesys 2's on-board oscillator is a 200 MHz LVDS
// differential pair (sysclk_p/sysclk_n), not a single-ended clock.
// IBUFDS converts it to single-ended, then MMCME2_BASE divides down
// to 100 MHz for the whole design -- chosen for margin: RPC=1 measured
// Fmax on this exact part is 304.04 MHz (reports/ppa_multidevice.csv),
// so 100 MHz leaves a very comfortable timing margin for a first
// hardware bring-up.
//
// IBUFDS/MMCME2_BASE are Xilinx UNISIM primitives with no behavioural
// model available to Icarus Verilog outside Vivado. `SIM_NO_MMCM`
// (defined only by tb/directed/tb_top_board.v's iverilog command
// line) bypasses both and feeds sysclk_p straight through as an
// ordinary single-ended clock, so the testbench can exercise every
// other block (UART, cmd_fsm, apb_master, ascon_apb) with a real
// clock edge without needing Vivado's simulation libraries.
// `SIM_NO_MMCM` must never be defined for an actual synthesis run --
// scripts/build_bitstream.tcl does not define it.

module top_board #(
    // Post-MMCM system clock frequency in Hz -- feeds uart_rx/uart_tx's
    // baud-rate divider. Real hardware always uses the 100 MHz default
    // (the MMCM below is hardwired for 200 MHz -> 100 MHz); overridden
    // only by tb/directed/tb_top_board.v (with SIM_NO_MMCM also
    // defined) to shrink the UART bit period and keep simulation fast.
    parameter CLK_FREQ_HZ = 100_000_000
) (
    input  wire       sysclk_p,
    input  wire       sysclk_n,
    input  wire       btnc,          // active-high pushbutton, board reset
    input  wire       uart_rx_out,   // FPGA RX (USB-UART bridge's TX)
    output wire       uart_tx_in,    // FPGA TX (USB-UART bridge's RX)
    output wire [7:0] led
);

    // ---- clock generation ----------------------------------------------
    wire clk_100m;
    wire mmcm_locked;

`ifdef SIM_NO_MMCM
    assign clk_100m    = sysclk_p;
    assign mmcm_locked = 1'b1;
`else
    wire clk_200m;
    wire clkfb, clkfb_buffered;
    wire clkout0_raw;

    IBUFDS #(
        .DIFF_TERM   ("TRUE"),
        .IBUF_LOW_PWR("FALSE"),
        .IOSTANDARD  ("DEFAULT")
    ) u_ibufds_sysclk (
        .O  (clk_200m),
        .I  (sysclk_p),
        .IB (sysclk_n)
    );

    // 200 MHz * 6 / 1 = 1200 MHz VCO (within MMCME2_BASE range),
    // /12 -> 100 MHz exactly.
    MMCME2_BASE #(
        .BANDWIDTH         ("OPTIMIZED"),
        .CLKFBOUT_MULT_F   (6.0),
        .CLKFBOUT_PHASE    (0.0),
        .CLKIN1_PERIOD     (5.000),
        .CLKOUT0_DIVIDE_F  (12.0),
        .CLKOUT0_DUTY_CYCLE(0.5),
        .CLKOUT0_PHASE     (0.0),
        .DIVCLK_DIVIDE     (1),
        .REF_JITTER1       (0.0),
        .STARTUP_WAIT      ("FALSE")
    ) u_mmcm (
        .CLKFBOUT (clkfb),
        .CLKFBOUTB(),
        .CLKOUT0  (clkout0_raw),
        .CLKOUT0B (),
        .CLKOUT1  (),
        .CLKOUT1B (),
        .CLKOUT2  (),
        .CLKOUT2B (),
        .CLKOUT3  (),
        .CLKOUT3B (),
        .CLKOUT4  (),
        .CLKOUT5  (),
        .CLKOUT6  (),
        .LOCKED   (mmcm_locked),
        .CLKFBIN  (clkfb_buffered),
        .CLKIN1   (clk_200m),
        .PWRDWN   (1'b0),
        .RST      (btnc)
    );

    BUFG u_bufg_fb   (.I(clkfb),       .O(clkfb_buffered));
    BUFG u_bufg_out0 (.I(clkout0_raw), .O(clk_100m));
`endif

    // ---- reset: MMCM lock ANDed with a synchronized, active-high --------
    // BTNC (button is asserted high; MMCM's own RST above is tied
    // straight to the raw button since MMCM reset is asynchronous by
    // design and cannot depend on the clock it produces).
    reg [1:0] btnc_sync;
    always @(posedge clk_100m) begin
        btnc_sync <= {btnc_sync[0], btnc};
    end
    wire rst_n = mmcm_locked & ~btnc_sync[1];

    // ---- UART <-> APB bridge --------------------------------------------
    wire [7:0]  rx_byte;
    wire        rx_byte_valid;
    wire [7:0]  tx_byte;
    wire        tx_byte_start;
    wire        tx_byte_done;

    wire        apb_start, apb_we, apb_done;
    wire [7:0]  apb_addr;
    wire [31:0] apb_wdata, apb_rdata;

    wire        psel, penable, pwrite, pready, pslverr;
    wire [7:0]  paddr;
    wire [31:0] pwdata, prdata;

    uart_rx #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ)
    ) u_uart_rx (
        .clk   (clk_100m),
        .rst_n (rst_n),
        .rx    (uart_rx_out),
        .data  (rx_byte),
        .valid (rx_byte_valid)
    );

    uart_tx #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ)
    ) u_uart_tx (
        .clk   (clk_100m),
        .rst_n (rst_n),
        .data  (tx_byte),
        .start (tx_byte_start),
        .tx    (uart_tx_in),
        .busy  (),
        .done  (tx_byte_done)
    );

    cmd_fsm u_cmd_fsm (
        .clk       (clk_100m),
        .rst_n     (rst_n),
        .rx_data   (rx_byte),
        .rx_valid  (rx_byte_valid),
        .tx_data   (tx_byte),
        .tx_start  (tx_byte_start),
        .tx_done   (tx_byte_done),
        .apb_start (apb_start),
        .apb_we    (apb_we),
        .apb_addr  (apb_addr),
        .apb_wdata (apb_wdata),
        .apb_rdata (apb_rdata),
        .apb_done  (apb_done)
    );

    apb_master u_apb_master (
        .clk             (clk_100m),
        .rst_n           (rst_n),
        .start           (apb_start),
        .we              (apb_we),
        .addr            (apb_addr),
        .wdata           (apb_wdata),
        .rdata           (apb_rdata),
        .done            (apb_done),
        .pslverr_latched (),
        .psel            (psel),
        .penable         (penable),
        .pwrite          (pwrite),
        .paddr           (paddr),
        .pwdata          (pwdata),
        .prdata          (prdata),
        .pready          (pready),
        .pslverr         (pslverr)
    );

    ascon_apb u_ascon_apb (
        .pclk    (clk_100m),
        .presetn (rst_n),
        .psel    (psel),
        .penable (penable),
        .pwrite  (pwrite),
        .paddr   (paddr),
        .pwdata  (pwdata),
        .prdata  (prdata),
        .pready  (pready),
        .pslverr (pslverr)
    );

    // ---- status LEDs ------------------------------------------------------
    // ascon_apb has no dedicated busy/done/tag_fail ports (only the
    // STATUS register, over APB) and rtl/ip/ must not be touched to
    // add any, so the LEDs are refreshed from the last STATUS read
    // apb_master actually performed. In practice the host driver polls
    // STATUS (opcode 0x03) in a tight loop while waiting for an
    // operation to finish, so the LEDs track real state with only the
    // small delay between polls -- see docs/spec.md 7.2 for the bit
    // layout (0=busy, 1=done, 4=tag_fail).
    localparam [7:0] ADDR_STATUS = 8'h04;

    reg [31:0] status_latched;
    always @(posedge clk_100m or negedge rst_n) begin
        if (!rst_n)
            status_latched <= 32'h0;
        else if (apb_done && !apb_we && (apb_addr == ADDR_STATUS))
            status_latched <= apb_rdata;
    end

    assign led[0]   = status_latched[0]; // busy
    assign led[1]   = status_latched[1]; // done
    assign led[6:2] = 5'b0;              // unused
    assign led[7]   = status_latched[4]; // tag_fail

endmodule
