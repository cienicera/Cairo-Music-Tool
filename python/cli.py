import argparse
from midi_conversion import midi_to_cairo_struct, midi_to_json, cairo_struct_to_midi

def main():
    parser = argparse.ArgumentParser(description='Convert MIDI files to and from Cairo or JSON format')
    parser.add_argument('input_file', type=str, help='Path to the input file')
    parser.add_argument('output_file', type=str, help='Path to the output file')
    parser.add_argument('--format', choices=['cairo', 'json', 'midi'], default='json', help='Output format: cairo, json, or midi (for converting back to MIDI)')

    args = parser.parse_args()

    if args.format == 'cairo':
        midi_to_cairo_struct(args.input_file, args.output_file)
        print(f"Converted {args.input_file} to Cairo format in {args.output_file} ✅")
    elif args.format == 'json':
        midi_to_json(args.input_file, args.output_file)
        print(f"Converted {args.input_file} to JSON format in {args.output_file} ✅")
    elif args.format == 'midi':
        cairo_struct_to_midi(args.input_file, args.output_file)
        print(f"Converted {args.input_file} from Cairo/JSON format back to MIDI in {args.output_file} ✅")

if __name__ == '__main__':
    main()
