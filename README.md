# plenv-ssl-doctor

plenv-ssl-doctor is plenv's plugin.

This plugin provides `ssl-doctor` sub-command to plenv.

```
$ plenv ssl-doctor
Usage:
  plenv ssl-doctor [install-net-ssleay]
```

For future release, `ssl-doctor` is taken its sub-command
as `plenv ssl-doctor install-net-ssleay` .

## Installation

```
mkdir -p $PLENV_ROOT/plugins
git clone git@github.com:xtetsuji/plenv-ssl-doctor.git $PLENV_ROOT/plugins/plenv-ssl-doctor
```

## Usage

### plenv ssl-doctor install-net-ssleay

Install `Net::SSLeay` by some methods.

## Author

OGATA Tetsuji <tetsuji.ogata@gmail.com>

## License

MIT License.
