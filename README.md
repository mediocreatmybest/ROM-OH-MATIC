# iPXE Prebuilt binary web interface

## Why

A Prebuilt binary web interface. Many users would prefer to be able to download prebuilt binary versions of iPXE, rather than building it from source.

## What

A web-based user interface that provide a way for the user to select any relevant iPXE build options, specify any embedded script, etc, and then construct and download the appropriate file.

## How

The user interface, is using HTML, CSS as well as Javascript (jQuery) and a suitable server-side language (such as Perl and PHP).
All GUI options (git version/nics list/compile options) are generated dynamicaly using PHP.
The build.fcgi script is written in Perl and was wrote by Michael Brown.

[![Docker build](https://github.com/mediocreatmybest/ROM-OH-MATIC/actions/workflows/docker.yml/badge.svg?branch=master)](https://github.com/mediocreatmybest/ROM-OH-MATIC/actions/workflows/docker.yml)
[![Docker pulls](https://img.shields.io/docker/pulls/mediocreatmybest/ipxe-buildweb)](https://hub.docker.com/r/mediocreatmybest/ipxe-buildweb)
[![Docker image size](https://img.shields.io/docker/image-size/mediocreatmybest/ipxe-buildweb/latest)](https://hub.docker.com/r/mediocreatmybest/ipxe-buildweb/tags)

> [!NOTE]
> This is a maintenance fork of [xbgmsharp/ipxe-buildweb](https://github.com/xbgmsharp/ipxe-buildweb), kept moving while the upstream repository is quiet. The intention is to preserve a working build, not to replace the original project. If the upstream becomes active again, the repository will be archived, rather than maintaining two versions for the fun of it.

Named after the great ROM-O-MATIC website, this web interface simplifies building iPXE binaries, allowing users to select relevant iPXE build options, provide an embedded script, and generate the required output without building it manually from the command line.

This repository is not part of, or endorsed by, the official [iPXE project](https://ipxe.org/), I don't have the neccessary skills for that!

## Current status

The Docker image is automatically built and published from `master`. Automated container startup, HTTP, and application-level iPXE generation tests will hopefully be added.

| Capability                    | Current status                             |
| ----------------------------- | ------------------------------------------ |
| Docker image build            | Automated on pushes to `master`            |
| Docker image publication      | Automated as part of the current build job |
| Container startup test        | TBD                                        |
| HTTP response test            | TBD                                        |
| iPXE artefact generation test | TBD                                        |
| Published platform            | `linux/amd64`                              |
| Current container base        | Ubuntu                                     |

A green build badge currently means that the image built and was published. It does not yet prove that the container started or is able to generate an iPXE artefact, but obviously it _should_.

## Docker image

The maintained image is published as:

```text
mediocreatmybest/ipxe-buildweb
```

Current tags are:

- `latest`: the most recent image published from `master`.
- `<full-git-commit-sha>`: the repository revision used to trigger the image build.

The published image currently targets `linux/amd64` only.

## Run with Docker

After [installing Docker](https://docs.docker.com/engine/install/), pull and run the maintained image:

```bash
docker pull mediocreatmybest/ipxe-buildweb:latest
docker run --detach \
  --publish 8080:80 \
  --name ipxe-buildweb   \
  mediocreatmybest/ipxe-buildweb:latest
```

Open <http://localhost:8080> in a browser.

Review the container state and logs with:

```bash
docker ps --filter name=ipxe-buildweb
docker logs ipxe-buildweb
```

For an interactive debugging shell in the running container:

```bash
docker exec -it ipxe-buildweb /bin/bash
```

Or start a temporary shell without launching the normal entrypoint:

```bash
docker run --rm -it \
  --entrypoint /bin/bash \
  mediocreatmybest/ipxe-buildweb:latest
```

The current image still contains a legacy SSH service and password-based root access. Port `22` is deliberately not published in the example above, but can be added to the `docker run` command if needed.

## Additional

The docker image contains the repository and iPXE source baseline. The current container also attempts a Git update when it starts; an explicit frozen mode is planned so versioned images can run without changing their included source.

Git TLS certificate verification is enabled by default. An explicit insecure compatibility option exists for controlled environments with broken proxy, MITM behaviour and/or certificate-inspection trust, in part, due to over zealous security muppets and a misguided view of the world, but installing the correct CA certificate is obviously preferred. The insecure option is intentionally not part of the normal quick start, but can be enabled within the ENV.

## Support and upstream projects

- Report problems with this maintenance fork through this repository's [issue tracker](https://github.com/mediocreatmybest/ROM-OH-MATIC/issues). I'll do my best to try and fix the build and/or container issues. _(Pull Requests WELCOME, please!!)_
- Refer to [xbgmsharp/ipxe-buildweb](https://github.com/xbgmsharp/ipxe-buildweb) for the original project and its history.
- Refer to [ipxe.org](https://ipxe.org/) and the [official iPXE repository](https://github.com/ipxe/ipxe) for questions and answers about the great iPXE project itself.

## Contributing

Any fixes or pull requests are welcome. Please keep changes small enough for me and test independently.

## Licence

This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. See [LICENSE](LICENSE).
