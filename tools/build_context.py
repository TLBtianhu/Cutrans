"""Generate immutable launch context and installer identity from product.zig."""
import argparse
import json
from pathlib import Path
from product import identity


def main():
    product = identity()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--form", choices=("development", "portable", "installed"), required=True)
    parser.add_argument("--channel", choices=("development", "preview", "stable"), default=product["default_channel"])
    parser.add_argument("--source-root", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--inno-output", type=Path)
    args = parser.parse_args()
    if args.form == "development" and (args.source_root is None or not args.source_root.is_absolute()):
        raise RuntimeError("development context requires an explicit absolute workspace root")
    context = {
        "format": "cutrans-run-context/1", "product_id": product["id"],
        "version": product["version"], "channel": args.channel, "form": args.form,
        "development_data_root": str(args.source_root.resolve() / ".cutrans-dev") if args.form == "development" else "",
        "services": {"updates": False, "accounts": False, "telemetry": False},
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(context, indent=2) + "\n", encoding="utf-8")
    if args.inno_output:
        macros = {"ProductId": product["id"], "ProductName": product["name"],
                  "ProductVersion": product["version"], "ProductAppId": "{" + product["app_id"],
                  "ProductProgId": product["document_progid"], "ProductExtension": product["document_extension"],
                  "ProductChannel": args.channel}
        args.inno_output.parent.mkdir(parents=True, exist_ok=True)
        args.inno_output.write_text("\n".join(f'#define {key} "{value}"' for key, value in macros.items()) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
