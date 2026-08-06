# iPXE Prebuilt binary web interface

## Why

A Prebuilt binary web interface. Many users would prefer to be able to download prebuilt binary versions of iPXE, rather than building it from source.

## What

A web-based user interface that provide a way for the user to select any relevant iPXE build options, specify any embedded script, etc, and then construct and download the appropriate file.

## How

The user interface is using HTML, CSS, and plain JavaScript (no frameworks or build step) with a suitable server-side language (such as Perl and PHP).
All GUI options (git version/nics list/compile options) are generated dynamically using PHP.
The build.fcgi script is written in Perl and was wrote by Michael Brown.

[![Docker build](https://github.com/mediocreatmybest/ROM-OH-MATIC/actions/workflows/docker.yml/badge.svg?branch=master)](https://github.com/mediocreatmybest/ROM-OH-MATIC/actions/workflows/docker.yml)
[![Docker pulls](https://img.shields.io/docker/pulls/mediocreatmybest/ipxe-buildweb)](https://hub.docker.com/r/mediocreatmybest/ipxe-buildweb)
[![Docker image size](https://img.shields.io/docker/image-size/mediocreatmybest/ipxe-buildweb/latest)](https://hub.docker.com/r/mediocreatmybest/ipxe-buildweb/tags)

> [!NOTE]
> This is a maintenance fork of [xbgmsharp/ipxe-buildweb](https://github.com/xbgmsharp/ipxe-buildweb), kept moving while the upstream repository is quiet. The intention is to preserve a working build, not to replace the original project. If the upstream becomes active again, the repository will be archived, rather than maintaining two versions for the fun of it.

Named after the great ROM-O-MATIC website, this web interface simplifies building iPXE binaries, allowing users to select relevant iPXE build options, provide an embedded script, and generate the required output without building it manually from the command line.

This repository is not part of, or endorsed by, the official [iPXE project](https://ipxe.org/), I don't have the necessary skills for that!

## Current status

The Docker image is automatically built and published from `master`. Automated container startup, HTTP, and application-level iPXE generation tests will hopefully be added.

| Capability                    | Current status                             |
| ----------------------------- | ------------------------------------------ |
| Docker image build            | Automated on pushes to `master`            |
| Docker image publication      | Automated as part of the current build job |
| Container startup test        | ✅                                         |
| HTTP response test            | ✅                                         |
| iPXE artefact generation test | ✅                                         |
| Published platform            | `linux/amd64`                              |
| Current container base        | Ubuntu 24.04 LTS                           |

A green build badge currently means that the image built and was published. It does not yet prove that the container started or is able to generate an iPXE artefact, but obviously it _should_.

## Docker image

The maintained image is published as:

```text
mediocreatmybest/ipxe-buildweb
```

Current tags are:

- `latest`: the most recent image published from `master`. This only ever moves once shell/Dockerfile validation, a real container start, and an actual iPXE build have all passed -- it never points at an untested build.
- `<full-git-commit-sha>` / `sha-<short-commit>`: the repository revision used to trigger the image build, in full and short form.

The published image currently targets `linux/amd64` only.

Each image also carries standard [OCI labels](https://github.com/opencontainers/image-spec/blob/main/annotations.md) (`org.opencontainers.image.revision`, `.created`, `.source`, etc.) plus a couple of project-specific ones -- `org.rom-oh-matic.ipxe.revision`, `org.rom-oh-matic.distribution`, `org.rom-oh-matic.distribution.version` -- so `docker inspect` can tell you exactly what's inside without needing to start the container. For example:

```bash
docker inspect mediocreatmybest/ipxe-buildweb:latest --format '{{json .Config.Labels}}'
```

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

SSH is off by default -- no hard-coded password, no default root access, and `sshd` never starts unless you explicitly ask for it. `docker exec` above is the normal way to get a shell. If you genuinely need SSH:

```bash
docker run --detach \
  --publish 8080:80 \
  --publish 2222:22 \
  --name ipxe-buildweb \
  --env ENABLE_SSH=true \
  --env SSH_AUTHORIZED_KEY="ssh-ed25519 AAAA... you@example.com" \
  mediocreatmybest/ipxe-buildweb:latest
```

`SSH_AUTHORIZED_KEY` (a public key) is preferred and gives key-only root login. `SSH_ROOT_PASSWORD` is available as a fallback if you'd rather use a password, but prefer the key where you can. Setting `ENABLE_SSH=true` without either one refuses to start `sshd` rather than falling back to anything insecure.

## Additional

The docker image contains the repository and iPXE source baseline. By default the container runs frozen -- exactly the revision baked in at build time, no network access required to start. Set `UPDATE_ON_START=true` to have it `git pull` on startup instead; a failed or unreachable update is logged and falls back to the existing baseline rather than breaking the container:

```bash
docker run --detach \
  --publish 8080:80 \
  --name ipxe-buildweb \
  --env UPDATE_ON_START=true \
  mediocreatmybest/ipxe-buildweb:latest
```

Git TLS certificate verification is enabled by default. An explicit insecure compatibility option exists for controlled environments with broken proxy, MITM behaviour and/or certificate-inspection trust, in part, due to over zealous security muppets and a misguided view of the world, but installing the correct CA certificate is obviously preferred. The insecure option is intentionally not part of the normal quick start, but can be enabled within the ENV:

```bash
docker run --detach \
  --publish 8080:80 \
  --name ipxe-buildweb \
  --env GIT_SSL_VERIFY=false \
  mediocreatmybest/ipxe-buildweb:latest
```

Only reach for this on a network you already trust to be doing the interception (e.g. a corporate proxy you can't get a CA cert out of). It doesn't disable every TLS check in the image, just Git's.

## Support and upstream projects

- Report problems with this maintenance fork through this repository's [issue tracker](https://github.com/mediocreatmybest/ROM-OH-MATIC/issues). I'll do my best to try and fix the build and/or container issues. _(Pull Requests WELCOME, please!!)_
- Refer to [xbgmsharp/ipxe-buildweb](https://github.com/xbgmsharp/ipxe-buildweb) for the original project and its history.
- Refer to [ipxe.org](https://ipxe.org/) and the [official iPXE repository](https://github.com/ipxe/ipxe) for questions and answers about the great iPXE project itself.

## Contributing

Any fixes or pull requests are welcome. Please keep changes small enough for me and test independently.

## License

This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. See [LICENSE](LICENSE).
