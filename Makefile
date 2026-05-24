CC = clang
CFLAGS = -O3 -fobjc-arc
FRAMEWORKS = -framework Foundation -framework AVFoundation -framework CoreMedia -framework Cocoa -framework CoreVideo -framework QuartzCore
TARGET = term-cam
SRC = term-cam.m
PREFIX = /usr/local

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) -o $(TARGET) $(FRAMEWORKS) $(SRC)

run: $(TARGET)
	./$(TARGET)

record: $(TARGET)
	./$(TARGET) 10

render:
	python3 render_ansi.py

clean:
	rm -f $(TARGET)
	rm -rf capture

install: $(TARGET)
	mkdir -p $(PREFIX)/bin
	cp -f $(TARGET) $(PREFIX)/bin/$(TARGET)
	chmod 755 $(PREFIX)/bin/$(TARGET)

uninstall:
	rm -f $(PREFIX)/bin/$(TARGET)

help:
	@echo "term-cam Makefile Targets:"
	@echo "  make          Compile binary (term-cam)"
	@echo "  make run      Compile and run with default highest quality"
	@echo "  make record   Compile and run, capturing frames every 10s"
	@echo "  make render   Bulk render all captured .ansi files to .jpg"
	@echo "  make clean    Remove compiled binary and capture/ directory"
	@echo "  make install  Install binary globally to $(PREFIX)/bin"
	@echo ""
	@echo "Runtime Key Controls (while running):"
	@echo "  h or ?        Toggle help menu overlay"
	@echo "  q, Esc        Quit the application cleanly"
	@echo "  s             Save manual screenshot to capture/"
	@echo "  Spacebar      Pause/Unpause video frame rendering"
	@echo "  m             Cycle mirror modes (None -> Horiz -> HorizSplit -> VertSplit)"
	@echo "  c             Cycle color maps (11 themes: Grayscale, Color, Green, Amber, Rainbow, Cyan, Red, Psychedelic, Inverted, Magenta, Spectral)"
	@echo "  [ or ]        Decrease/Increase contrast factor"
	@echo "  + or =        Increase resolution (decrease pixel block size)"
	@echo "  -             Decrease resolution (increase pixel block size)"

.PHONY: all run record render clean install uninstall help
