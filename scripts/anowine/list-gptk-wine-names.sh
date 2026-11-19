#!/bin/bash
# Lists every "wine" name inside Apple's Game Porting Toolkit as Ano imported
# it (D3DMetal.framework, libd3dshared.dylib and the DLLs that load them), so
# the rename can keep the Wine names D3DMetal needs as hidden aliases.
#
# Run on your Mac:  bash ~/Downloads/list-gptk-wine-names.sh [folder]
# The folder defaults to Ano's own copy of the toolkit. The list is printed
# and saved to ~/Desktop/ano-gptk-wine-names.txt. Nothing is changed.
# Uses only bash, find and perl, which every Mac has.
set -euo pipefail

store=${1:-"$HOME/Library/Application Support/io.github.highstormpvp.Ano/D3DMetal"}
if [ ! -d "$store" ]; then
  echo "No Game Porting Toolkit has been imported in Ano (looked in: $store)." >&2
  echo "Import it in Ano's settings first, or pass the folder that holds it." >&2
  exit 1
fi
out="$HOME/Desktop/ano-gptk-wine-names.txt"
mkdir -p "$HOME/Desktop"
cd "$store"

{
  echo "# Wine names in Apple's Game Porting Toolkit, as imported in Ano"
  echo "# date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "# folder: $store ($(find . -type f | wc -l | tr -d ' ') files)"
  printf '# paths:   <path>\t<dir|file|link>[\t<link target>]\n'
  printf '# strings: <path>\t<ascii|utf16>\t<count>\t<string, up to 200 characters>\n'

  # Paths with "wine" in them, and links whose target has it.
  find . -mindepth 1 -print0 | perl -0 -e '
    my @paths = sort map { chomp; s{^\./}{}; $_ } <STDIN>;
    for my $path (@paths) {
      if (-l $path) {
        my $target = readlink($path) // "";
        print "$path\tlink\t$target\n" if "$path\t$target" =~ /wine/i;
      } elsif ($path =~ /wine/i) {
        print "$path\t", (-d $path ? "dir" : "file"), "\n";
      }
    }'

  # Strings with "wine" in every regular file: runs of 4 or more printable
  # ASCII bytes, and of 4 or more UTF-16LE characters. A UTF-16 run does not
  # start on a byte that ends ASCII text ("DLL\0" then UTF-16 "Wine").
  find . -type f -print0 | perl -0 -e '
    my @files = sort map { chomp; s{^\./}{}; $_ } <STDIN>;
    for my $file (@files) {
      open(my $fh, "<:raw", $file) or next;
      my $data = do { local $/; <$fh> };
      close($fh);
      my %count;
      while ($data =~ /([\x20-\x7e]{4,})/g) {
        my $text = $1;
        $count{"ascii\t" . substr($text, 0, 200)}++ if $text =~ /wine/i;
      }
      while ($data =~ /(?<![\x20-\x7e])((?:[\x20-\x7e]\x00){4,})/g) {
        (my $text = $1) =~ s/\x00//g;
        $count{"utf16\t" . substr($text, 0, 200)}++ if $text =~ /wine/i;
      }
      for my $key (sort keys %count) {
        my ($kind, $text) = split /\t/, $key, 2;
        print "$file\t$kind\t$count{$key}\t$text\n";
      }
    }'
} | tee "$out"
echo "Saved to $out" >&2
