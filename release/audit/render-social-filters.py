#!/usr/bin/env python3
"""Materialize literal URL exceptions for the existing GNU sed audit pipeline."""
import json
from pathlib import Path
import sys


def literal(value):
    if not isinstance(value, str) or not value.startswith(('https://', 'http://')) or any(ord(c) < 32 for c in value):
        raise ValueError('Invalid social URL exception')
    # Escape BRE metacharacters and the sed delimiter, rather than Python regex.
    return ''.join(('\\' if char in '\\.[*^$#' else '') + char for char in value)


def render(policy):
    text = ['s#' + literal(url) + '##gI' for url in policy['allowedSocialUrls']]
    seeds = ['s#"' + literal(url) + '"#""#g' for url in policy['allowedSeedSocialUrls']]
    return '\n'.join(text) + '\n', '\n'.join(seeds) + '\n'


if __name__ == '__main__':
    try:
        text, seeds = render(json.loads(Path(sys.argv[1]).read_text())['audit'])
        output = Path(sys.argv[2])
        (output / 'social-text.sed').write_text(text)
        (output / 'social-seeds.sed').write_text(seeds)
    except (ValueError, KeyError, TypeError, OSError) as error:
        sys.exit(f'Cannot render social URL exceptions: {error}')
