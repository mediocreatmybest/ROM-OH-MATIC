# iPXE Prebuilt binary web interface

## Why

A Prebuilt binary web interface. Many users would prefer to be able to download prebuilt binary versions of iPXE, rather than building it from source.

## What

A web-based user interface that provide a way for the user to select any relevant iPXE build options, specify any embedded script, etc, and then construct and download the appropriate file.

## How

The user interface is using HTML, CSS, and plain JavaScript (no frameworks or build step) with a suitable server-side language (such as Perl and PHP).
All GUI options (git version/nics list/compile options) are generated dynamically using PHP.
The build.fcgi script is written in Perl and was wrote by Michael Brown.

[![Docker build (Ubuntu)](https://github.com/mediocreatmybest/ROM-OH-MATIC/actions/workflows/docker-ubuntu.yml/badge.svg?branch=master)](https://github.com/mediocreatmybest/ROM-OH-MATIC/actions/workflows/docker-ubuntu.yml)
[![Docker build (Alpine)](https://github.com/mediocreatmybest/ROM-OH-MATIC/actions/workflows/docker-alpine.yml/badge.svg?branch=master)](https://github.com/mediocreatmybest/ROM-OH-MATIC/actions/workflows/docker-alpine.yml)
[![Docker image size (Ubuntu)](https://img.shields.io/docker/image-size/mediocreatmybest/ipxe-buildweb/latest?label=image%20size%20%28ubuntu%29)](https://hub.docker.com/r/mediocreatmybest/ipxe-buildweb/tags)
[![Docker image size (Alpine)](https://img.shields.io/docker/image-size/mediocreatmybest/ipxe-buildweb/latest-alpine?label=image%20size%20%28alpine%29)](https://hub.docker.com/r/mediocreatmybest/ipxe-buildweb/tags)
[![Docker pulls](https://img.shields.io/docker/pulls/mediocreatmybest/ipxe-buildweb)](https://hub.docker.com/r/mediocreatmybest/ipxe-buildweb)

> [!NOTE]
> This is a maintenance fork of [xbgmsharp/ipxe-buildweb](https://github.com/xbgmsharp/ipxe-buildweb), kept moving while the upstream repository is quiet. The intention is to preserve a working build, not to replace the original project. If the upstream becomes active again, the repository will be archived, rather than maintaining two versions for the fun of it.

Named after the great ROM-O-MATIC website, this web interface simplifies building iPXE binaries, allowing users to select relevant iPXE build options, provide an embedded script, and generate the required output without building it manually from the command line.

The advanced wizard can additionally offer two certificate features, aimed at self-hosted deployments on a network you control:

- **HTTPS certificate trust**: build iPXE to trust a private CA or self-signed certificate, for a PXE/HTTPS server that doesn't use a publicly-trusted one.
- **Secure Boot signing and verification**: sign a built EFI binary with a Secure Boot key you already hold and have enrolled yourself, and check whether any EFI binary's signature matches a given public certificate. Nothing here generates, stores or enrols keys.

Both are **off by default** -- they handle certificate and private key material, so a deployment only offers them if you ask it to. Turn them on with [`UI_ENABLE_CERT_FEATURE`](#additional) below.

This repository is not part of, or endorsed by, the official [iPXE project](https://ipxe.org/), I don't have the necessary skills for that!

## Current status

The Docker image is automatically built and published from `master`. Every build runs automated container startup, HTTP, and application-level iPXE generation tests before the image is published.

| Capability                       | Current status                                                         |
| -------------------------------- | ---------------------------------------------------------------------- |
| Docker image build               | Automated on pushes to `master`, Ubuntu and Alpine built independently |
| Docker image publication         | Automated as part of each build's own workflow                         |
| Container startup test           | ✅                                                                     |
| HTTP response test               | ✅                                                                     |
| iPXE artefact generation test    | ✅                                                                     |
| Certificate trust build test     | ✅                                                                     |
| Secure Boot sign and verify test | ✅                                                                     |
| Published platform               | `linux/amd64`                                                          |
| Container bases                  | Ubuntu 24.04 LTS (default), Alpine 3.20                                |

A green build badge means that variant's image built, started successfully, responded over HTTP, and produced a working iPXE artefact, before being published. Ubuntu and Alpine build and publish independently, so one badge can be green while the other is red.

## Docker image

The maintained image is published as:

```text
mediocreatmybest/ipxe-buildweb
```

Current tags are:

- `latest`: the most recent image published from `master`. This only ever moves once shell/Dockerfile validation, a real container start, and an actual iPXE build have all passed -- it never points at an untested build.
- `<full-git-commit-sha>` / `sha-<short-commit>`: the repository revision used to trigger the image build, in full and short form.
- `staging`: the current tip of the `staging` branch, published under the same pass/fail gate as `latest`. Separate from it entirely -- a `staging` push never moves `latest` or the SHA tags, and a `master` push never moves `staging`. Pull it to check a change before merging, without a local build:

  ```bash
  docker pull mediocreatmybest/ipxe-buildweb:staging
  ```

- `latest-alpine` / `<full-git-commit-sha>-alpine` / `sha-<short-commit>-alpine` / `staging-alpine`: the same application, built on Alpine 3.20 instead of Ubuntu, under the same tests and pass/fail gate as their non-suffixed counterparts. Smaller image, otherwise equivalent -- same scripts, same feature set:

  ```bash
  docker pull mediocreatmybest/ipxe-buildweb:latest-alpine
  ```

The published image currently targets `linux/amd64` only.

Each image also carries standard [OCI labels](https://github.com/opencontainers/image-spec/blob/main/annotations.md) (`org.opencontainers.image.revision`, `.created`, `.source`, etc.) plus a couple of project-specific ones -- `org.rom-oh-matic.ipxe.revision`, `org.rom-oh-matic.distribution`, `org.rom-oh-matic.distribution.version` -- so `docker inspect` can tell you exactly what's inside without needing to start the container. For example:

```bash
docker inspect mediocreatmybest/ipxe-buildweb:latest --format '{{json .Config.Labels}}'
```

## Run with Docker Compose

The simplest way to get running: `docker-compose.yml` covers both published variants from the same Dockerfile, without composing a `docker run` command by hand. Ubuntu is the default -- no flag needed:

```bash
docker compose up -d
```

Open <http://localhost:8080>. Alpine is opt-in, via its own profile -- name the service too, so only Alpine starts rather than Alpine _and_ the still-default Ubuntu service:

```bash
docker compose --profile alpine up -d alpine
```

Open <http://localhost:8081> (a different port from Ubuntu's 8080, so both can run side by side if you ever want to compare them directly). Both build locally by default; to use the published images instead, pull first and skip the build:

```bash
docker compose pull ubuntu
docker compose up -d --no-build
```

`ENABLE_SSH`, `UPDATE_ON_START`, `UI_ENABLE_CERT_FEATURE`, `GIT_SSL_VERIFY` and friends are all read from the environment -- set them in a `.env` file next to `docker-compose.yml`, or on the command line:

```bash
UI_ENABLE_CERT_FEATURE=true docker compose up -d
```

## Run with plain `docker run`

Compose above is the easier path for most people. If you'd rather not have a `docker-compose.yml` in the mix -- a one-off test, scripting a deploy yourself, no Compose installed -- the same image runs fine on its own. After [installing Docker](https://docs.docker.com/engine/install/):

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

Certificate/key handling -- HTTPS certificate trust and Secure Boot signing/verification -- is off by default. Those sections handle certificate and private key material, so a deployment doesn't offer them unless you say so. Enable both with:

```bash
docker run --detach \
  --publish 8080:80 \
  --name ipxe-buildweb \
  --env UI_ENABLE_CERT_FEATURE=true \
  mediocreatmybest/ipxe-buildweb:latest
```

Left off, this is more than a hidden UI section: the markup isn't served at all, and `build.fcgi` and `verify.fcgi` refuse the corresponding fields outright -- including a request posted straight at them, bypassing the page. Everything else (normal iPXE builds, embedded scripts, build options, presets) is unaffected either way.

## Support and upstream projects

- Report problems with this maintenance fork through this repository's [issue tracker](https://github.com/mediocreatmybest/ROM-OH-MATIC/issues). I'll do my best to try and fix the build and/or container issues. _(Pull Requests WELCOME, please!!)_
- Refer to [xbgmsharp/ipxe-buildweb](https://github.com/xbgmsharp/ipxe-buildweb) for the original project and its history.
- Refer to [ipxe.org](https://ipxe.org/) and the [official iPXE repository](https://github.com/ipxe/ipxe) for questions and answers about the great iPXE project itself.

## Contributing

Any fixes or pull requests are welcome. Please keep changes small enough for me and test independently.

## License

This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. See [LICENSE](LICENSE).
