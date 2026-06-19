from pathlib import Path

from PIL import Image


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    source = root / "assets" / "AppIcon.png"
    target = root / "assets" / "AppIcon.icns"

    image = Image.open(source).convert("RGBA")
    sizes = [(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)]
    icon_frames = [image.resize(size, Image.Resampling.LANCZOS) for size in sizes]
    icon_frames[0].save(target, format="ICNS", append_images=icon_frames[1:])
    print(target)


if __name__ == "__main__":
    main()
