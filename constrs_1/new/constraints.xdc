# ------------------------------------------------------------------------------
# System Clock (200 MHz) - Bank 84
# ------------------------------------------------------------------------------
set_property PACKAGE_PIN AC13 [get_ports sys_clk_p]
set_property PACKAGE_PIN AC14 [get_ports sys_clk_n]
set_property IOSTANDARD DIFF_SSTL12 [get_ports sys_clk_p]
create_clock -period 5.000 -name sys_clk [get_ports sys_clk_p]

# ------------------------------------------------------------------------------
# GTY Reference Clock (125 MHz from FMC Module) - Bank 226
# ------------------------------------------------------------------------------
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets sys_clk_buf/O]

# Mapping: FMC_HPC_GBTCLK0_M2C_CP -> M7
# Mapping: FMC_HPC_GBTCLK0_M2C_CN -> M6
set_property PACKAGE_PIN M7 [get_ports gt_refclk_p]
set_property PACKAGE_PIN M6 [get_ports gt_refclk_n]
create_clock -period 8.000 -name gt_refclk [get_ports gt_refclk_p]

# ------------------------------------------------------------------------------
# SFP1 Interface (Bank 226)
# ------------------------------------------------------------------------------
# TX Mapping: FMC_DP0_C2M -> N5/N4
# RX Mapping: FMC_DP0_M2C -> M2/M1
set_property PACKAGE_PIN N5 [get_ports sfp_tx_p]
set_property PACKAGE_PIN N4 [get_ports sfp_tx_n]
set_property PACKAGE_PIN M2 [get_ports sfp_rx_p]
set_property PACKAGE_PIN M1 [get_ports sfp_rx_n]

# ------------------------------------------------------------------------------
# LEDs (Bank 87)
# ------------------------------------------------------------------------------
set_property PACKAGE_PIN J12 [get_ports {led[0]}]
set_property PACKAGE_PIN H14 [get_ports {led[1]}]
set_property PACKAGE_PIN F13 [get_ports {led[2]}]
set_property PACKAGE_PIN H12 [get_ports {led[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[*]}]

# ------------------------------------------------------------------------------
# Reset (Key 1 - Bank 87)
# ------------------------------------------------------------------------------
set_property PACKAGE_PIN J14 [get_ports rst_n_i]
set_property IOSTANDARD LVCMOS33 [get_ports rst_n_i]

set_property PACKAGE_PIN J15 [get_ports bot_trig_n_i]
set_property IOSTANDARD LVCMOS33 [get_ports bot_trig_n_i]

# UART
set_property PACKAGE_PIN AD15 [get_ports uart_tx]
set_property IOSTANDARD LVCMOS33 [get_ports uart_tx]

set_property PACKAGE_PIN AE15 [get_ports uart_rx]
set_property IOSTANDARD LVCMOS33 [get_ports uart_rx]

# ------------------------------------------------------------------------------
# Timing Exceptions
# ------------------------------------------------------------------------------
# Ignore timing between the 50MHz DRP clock and the 125MHz Core clock
# (The IP handles CDC internally for the most part)
set_false_path -from [get_clocks -of_objects [get_pins sys_pll_inst/inst/mmcme4_adv_inst/CLKOUT0]] -to [get_clocks -of_objects [get_pins gt_refclk_buf/O]]
set_false_path -from [get_clocks -of_objects [get_pins gt_refclk_buf/O]] -to [get_clocks -of_objects [get_pins sys_pll_inst/inst/mmcme4_adv_inst/CLKOUT0]]