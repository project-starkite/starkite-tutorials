FROM ghcr.io/project-starkite/starkite:v0.11.8

COPY init_bootstrap.star /scripts/init_bootstrap.star

USER 65532:65532
ENTRYPOINT ["kite", "run", "/scripts/init_bootstrap.star"]
CMD [ \
    "--sandbox-path-read=/scripts", \
    "--sandbox-path-read=/var/run/secrets/kubernetes.io/serviceaccount", \
    "--sandbox-path-write=/work/shared", \
    "--sandbox-net-allow", \
    "--env=KUBERNETES_SERVICE_HOST", \
    "--env=KUBERNETES_SERVICE_PORT", \
    "--var=out.dir=/work/shared" \
]
