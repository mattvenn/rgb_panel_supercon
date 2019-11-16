#Badge version. Green (unused) is 1, red is 2, blue is 3, prod (black) is 4
BADGE_VER ?= 2
#Project name
PROJ=rgb_badge
#Seed for nextpnr. Change this to another random value if you happen to run 
#into a situation that mis-synths or takes extremely long to synth the SoC.
SEED = 37

# Sources
	# Base
SRC = \
	rtl/pgen.v \
	rtl/sysmgr.v \
	rtl/top.v \
	rtl/vgen.v \
	$(NULL)

SRC += $(addprefix hub75/rtl/, \
	hub75_bcm.v \
	hub75_blanking.v \
	hub75_colormap.v \
	hub75_fb_readout.v \
	hub75_fb_writein.v \
	hub75_framebuffer.v \
	hub75_gamma.v \
	hub75_init_inject.v \
	hub75_linebuffer.v \
	hub75_phy_ddr.v \
	hub75_phy.v \
	hub75_scan.v \
	hub75_shift.v \
	hub75_top.v \
)

TRELLIS=/usr/share/trellis

ifeq ($(OS),Windows_NT)
EXE:=.exe
endif
ifneq ("$(WSL_DISTRO_NAME)","")
	# if using Windows Subsystem for Linux, and yosys not found, try adding .exe
	ifeq (, $(shell which yosys))
		EXE:=.exe
 	endif
endif

all: $(PROJ).svf

$(PROJ).json $(PROJ).blif: $(SRC) $(SRC_SYNTH) $(EXTRA_DEPEND)
	yosys$(EXE) -e ".*(assigned|implicitly).*" -l yosys.log \
		-p "read -sv -DBADGE_VER=$(BADGE_VER) -DBADGE_V$(BADGE_VER)=1 $(SRC) $(SRC_SYNTH); \
			  synth_ecp5 -abc9 -top top -json $(PROJ).json -blif $(PROJ).blif"

%_out_synth.config: %.json clock-constrainsts.py
	nextpnr-ecp5$(EXE) --json $< --lpf $(CONSTR) --textcfg $@ --45k --package CABGA381 --speed 8 \
			--pre-pack clock-constrainsts.py -l nextpnr.log --freq 48 --seed $(SEED)

%_out.config: %_out_synth.config rom.hex
	ecpbram -i $< -o $@ -f rom_random_seeds0x123456.hex -t rom.hex

#Note: can't generate bit and svf at the same time as some silicon revs of the ECP5 don't seem to accept
#bitstreams with SPI-specific things over JTAG.

%.bit: %_out.config
	ecppack$(EXE) --spimode $(FLASH_MODE) --freq $(FLASH_FREQ) --input $< --bit $@

%.svf: %_out.config
	ecppack$(EXE) --svf-rowsize 100000 --svf $@ --input $<

prog: $(PROJ).svf
	openocd -f ../openocd.cfg -c "init; svf  $<; exit"

flash: $(PROJ).bit
	tinyprog -p $(PROJ).bit -a 0x180000

dfu_flash: $(PROJ).bit
	dfu-util$(EXE) -d 1d50:614a,1d50:614b -a 0 -R -D $<

dfu_flash_all: $(PROJ).bit ipl
	dfu-util$(EXE) -d 1d50:614a,1d50:614b -a 0 -D $(PROJ).bit
	dfu-util$(EXE) -d 1d50:614a,1d50:614b -a 1 -D ipl/ipl.bin -R

dfu_flash_all_cart: $(PROJ).bit ipl
	dfu-util$(EXE) -d 1d50:614a,1d50:614b -a 2 -D $(PROJ).bit
	dfu-util$(EXE) -d 1d50:614a,1d50:614b -a 3 -D ipl/ipl.bin -R

clean:
	rm -f $(PROJ).json $(PROJ).svf $(PROJ).bit $(PROJ)_out.config
	rm -rf verilator-build
	$(MAKE) -C boot clean
	rm -f rom.hex

verilator: verilator-build/Vsoc ipl boot/ $(EXTRA_DEPEND)
	./verilator-build/Vsoc

ifeq ("$(VCD)","")
VR_TRACE_OPTS := --trace-fst-thread
VR_TRACE_CFLAGS := -DVERILATOR_USE_FST=1
else
VR_TRACE_OPTS := --trace
VR_TRACE_CFLAGS := -DVERILATOR_USE_VCD=1
endif

verilator-build/Vsoc: $(SRC) $(SRC_SIM) $(BRAMFILE)
	verilator -Iusb -CFLAGS "-ggdb `sdl2-config --cflags` $(VR_TRACE_CFLAGS)" -LDFLAGS "`sdl2-config --libs`" --assert \
			$(VR_TRACE_OPTS) --Mdir verilator-build -Wno-style -Wno-fatal -cc --top-module soc \
			-O3 --noassert --exe $(SRC) $(SRC_SIM)
	$(MAKE) OPT_FAST="-O2 -fno-stack-protector" -C verilator-build -f Vsoc.mk

rom.hex: boot/
	$(MAKE) -C boot
ifeq ($(OS),Windows_NT)
	bin2hex.exe boot/rom.bin rom.hex
else
	cat boot/rom.bin | hexdump -v -e '/4 "%08X\n"' > rom.hex
endif

gdb:
	$(GDB) -b 115200 -ex "set debug remote 1" -ex "target remote /dev/ttyUSB0" app/app.elf

pcpi_fastmul_dsp_testbench:
	iverilog -opcpi_fastmul_dsp_testbench.vvp pcpi_fastmul_dsp_testbench.v pcpi_fastmul_dsp.v picorv32/picorv32.v mul_18x18_sim.v
	vvp pcpi_fastmul_dsp_testbench.vvp

pic/rom_initial.hex: pic/rom.asm
	$(MAKE) -C pic rom_initial.hex

ipl:
	$(MAKE) -C ipl

.PHONY: prog clean verilator boot/ ipl
.PRECIOUS: $(PROJ).json $(PROJ)_out_synth.config $(PROJ)_out.config

