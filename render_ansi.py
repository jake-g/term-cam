import os
import re
import sys
import glob
from PIL import Image, ImageDraw, ImageFont

def render_file(input_path, output_path, font, char_w, char_h):
    with open(input_path, "r", encoding="utf-8") as f:
        text = f.read()
        
    text = text.replace('\x1b[0;0H', '').replace('\x1b[2J', '').replace('\x1b[?25l', '')
    
    lines = text.split('\n')
    if not lines:
        return False
        
    grid = []
    max_cols = 0
    pattern = re.compile(r'\x1b\[([^m]+)m')
    
    for line in lines:
        if not line:
            continue
        row = []
        pos = 0
        bg_r, bg_g, bg_b = 0, 0, 0
        fg_r, fg_g, fg_b = 255, 255, 255
        
        while pos < len(line):
            match = pattern.match(line, pos)
            if match:
                seq = match.group(1)
                parts = seq.split(';')
                if len(parts) >= 5 and parts[1] == '2':
                    r = int(parts[2])
                    g = int(parts[3])
                    b = int(parts[4])
                    if parts[0] == '48':
                        bg_r, bg_g, bg_b = r, g, b
                    elif parts[0] == '38':
                        fg_r, fg_g, fg_b = r, g, b
                pos = match.end()
            else:
                char = line[pos]
                row.append((char, (bg_r, bg_g, bg_b), (fg_r, fg_g, fg_b)))
                pos += 1
        if row:
            grid.append(row)
            max_cols = max(max_cols, len(row))
            
    if not grid:
        return False
        
    rows = len(grid)
    img_w = max_cols * char_w
    img_h = rows * char_h
    
    img = Image.new("RGB", (img_w, img_h), (0, 0, 0))
    draw = ImageDraw.Draw(img)
    
    for y, row in enumerate(grid):
        for x, cell in enumerate(row):
            char, bg, fg = cell
            rx = x * char_w
            ry = y * char_h
            draw.rectangle([rx, ry, rx + char_w, ry + char_h], fill=bg)
            draw.text((rx, ry - 1), char, font=font, fill=fg)
            
    img.save(output_path, "JPEG", quality=90)
    print(f"Rendered: {os.path.basename(input_path)} -> {os.path.basename(output_path)}")
    return True

def main():
    # Setup font
    font_path = "/System/Library/Fonts/Monaco.ttf"
    if not os.path.exists(font_path):
        font_path = "/System/Library/Fonts/Supplemental/Courier New.ttf"
        
    font_size = 14
    try:
        font = ImageFont.truetype(font_path, font_size)
    except:
        font = ImageFont.load_default()
        
    # Measure character size
    bbox = font.getbbox("A")
    char_w = bbox[2] - bbox[0]
    char_h = bbox[3] - bbox[1] + 2
    
    if len(sys.argv) >= 3:
        # Command line render single file
        render_file(sys.argv[1], sys.argv[2], font, char_w, char_h)
    else:
        # Bulk render files in capture/ directory
        capture_dir = "capture"
        if not os.path.exists(capture_dir):
            print(f"Directory '{capture_dir}' does not exist.")
            return
            
        ansi_files = glob.glob(os.path.join(capture_dir, "*.ansi"))
        if not ansi_files:
            print(f"No .ansi files found in '{capture_dir}'.")
            return
            
        rendered_count = 0
        for ansi_file in sorted(ansi_files):
            base_path = os.path.splitext(ansi_file)[0]
            jpg_file = base_path + ".jpg"
            if not os.path.exists(jpg_file):
                if render_file(ansi_file, jpg_file, font, char_w, char_h):
                    rendered_count += 1
                    
        if rendered_count == 0:
            print("All captures are already rendered.")
        else:
            print(f"Successfully bulk rendered {rendered_count} new image(s).")

if __name__ == "__main__":
    main()
