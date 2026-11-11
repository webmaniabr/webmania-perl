# Tested runtime boundary

This preview is tested only on Debian bookworm Linux aarch64, Perl 5.36.0 (Debian `perl-base`), with the pinned native dependencies in dependencies.lock.json. This is a Debian-maintained runtime, not a claim that Perl 5.36 is a currently maintained upstream Perl release. Debian documents [bookworm LTS through June 2028](https://www.debian.org/News/2026/20260712) and [LTS architecture/package scope](https://wiki.debian.org/LTS/Bookworm). That lifecycle statement is not a claim that this frozen image automatically receives future security updates.

No macOS, Windows, upstream-current Perl release, threads, embedded runtime, native mobile platform or alternative SSL backend is qualified. Run local tests in the prepared Docker image selected by WEBMANIA_PERL_IMAGE; see scripts/qualify_docker.sh. Refreshing native dependencies or base images requires new qualification.

Resolver workers use fork, which copies interpreter memory and execution context. Before native getaddrinfo, the Linux worker enumerates /proc/self/fd and closes inherited descriptors except its owned IPC writer; the parent's descriptor table is not changed. Resolver-created descriptors belong to that bounded worker. This is not a fresh interpreter/exec security boundary. Parent timeout/cancellation kills and reaps the child before returning.
