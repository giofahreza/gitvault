#!/usr/bin/env python3
"""Add padding to app icon for adaptive icon foreground"""

from PIL import Image
import sys

def add_padding(input_path, output_path, padding_percent=15):
    """
    Add padding around an image

    Args:
        input_path: Path to input image
        output_path: Path to save output image
        padding_percent: Percentage of padding (15 means 15% on each side, 70% content)
    """
    # Open the image
    img = Image.open(input_path)

    # Convert to RGBA if not already
    if img.mode != 'RGBA':
        img = img.convert('RGBA')

    # Calculate new size with padding
    old_width, old_height = img.size

    # Calculate padding
    padding_x = int(old_width * padding_percent / 100)
    padding_y = int(old_height * padding_percent / 100)

    new_width = old_width + (2 * padding_x)
    new_height = old_height + (2 * padding_y)

    # Create new image with transparent background
    new_img = Image.new('RGBA', (new_width, new_height), (0, 0, 0, 0))

    # Resize original image to fit in the center (leave room for padding)
    content_width = new_width - (2 * padding_x)
    content_height = new_height - (2 * padding_y)

    img_resized = img.resize((content_width, content_height), Image.Resampling.LANCZOS)

    # Paste the resized image in the center
    new_img.paste(img_resized, (padding_x, padding_y), img_resized)

    # Save
    new_img.save(output_path, 'PNG')
    print(f"✓ Created padded icon: {output_path}")
    print(f"  Original size: {old_width}x{old_height}")
    print(f"  New size: {new_width}x{new_height}")
    print(f"  Padding: {padding_percent}% ({padding_x}px horizontal, {padding_y}px vertical)")

if __name__ == '__main__':
    input_file = 'assets/icon/gitvault.png'
    output_file = 'assets/icon/gitvault_padded.png'

    try:
        add_padding(input_file, output_file, padding_percent=20)
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)
