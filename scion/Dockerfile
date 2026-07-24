# SCION infrastructure image for the dev-scripts local SCION topology.
# Built locally at configure time; never pushed to a registry.
FROM docker.io/library/golang:1.26 AS scion-build
ARG SCION_VERSION=v0.15.0
RUN git clone --depth 1 -b ${SCION_VERSION} https://github.com/scionproto/scion /src
WORKDIR /src
# control and daemon need cgo: their sqlite storage backend (go-sqlite3)
# is a stub without it. Link them statically (netgo/osusergo) so the
# binaries run on the ubi9 glibc, which is older than the builder's.
RUN CGO_ENABLED=1 go build -tags netgo,osusergo -ldflags '-extldflags "-static"' \
        -o /out/scion-control ./control/cmd/control && \
    CGO_ENABLED=1 go build -tags netgo,osusergo -ldflags '-extldflags "-static"' \
        -o /out/scion-daemon ./daemon/cmd/daemon && \
    CGO_ENABLED=0 go build -o /out/scion-router ./router/cmd/router && \
    CGO_ENABLED=0 go build -o /out/scion-dispatcher ./dispatcher/cmd/dispatcher && \
    CGO_ENABLED=0 go build -o /out/scion-ip-gateway ./gateway/cmd/gateway && \
    CGO_ENABLED=0 go build -o /out/scion-pki ./scion-pki/cmd/scion-pki && \
    CGO_ENABLED=0 go build -o /out/scion ./scion/cmd/scion

FROM docker.io/library/golang:1.26 AS registrar-build
ARG SCION_OPERATOR_REF=main
# `go install ...@ref` fails sumdb verification for fresh commits, so build
# from a git clone instead.
RUN git clone https://github.com/mkowalski/scion-k8s-operator /src && \
    cd /src && git checkout ${SCION_OPERATOR_REF} && \
    CGO_ENABLED=0 go build -o /out/registrar ./cmd/registrar

FROM registry.access.redhat.com/ubi9/ubi-minimal
RUN microdnf install -y python3 iproute && microdnf clean all
COPY --from=scion-build /out/ /usr/local/bin/
COPY --from=registrar-build /out/registrar /usr/local/bin/scion-registrar
COPY serve-discovery.py /usr/local/bin/serve-discovery.py
# No ENTRYPOINT: each container picks its binary via podman --entrypoint,
# keeping the scion binary as PID 1 so `podman kill -s HUP` reaches it.
