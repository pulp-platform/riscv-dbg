# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2019-05-16

### Added
- Parametrize buswidth to support 32-bit and 64-bit cores
- Support arbitrary base addresses in debug ROM
- Add misc helper functions to facilitate code generation
- Add README
- Fork from Ariane

### Changed
- Allow generic number of data registers
- Make JTAG IDCODE parametrizable

### Removed
- Remove ariane specific packages

### Fixed
- Add missing JTAG test logic reset handling
- Fix resume logic in multihart situations
- Fix missing else(s) in system bus access
- Fix bad transitions into program buffer
- Fix error handling when using unsupported abstract commands
- Prevent harts from being in multiple states
- Fix various style issues
