FROM alpine:3.20

RUN apk add --no-cache \
	openldap \
	openldap-clients \
	openldap-back-mdb \
	openldap-overlay-memberof \
	openldap-overlay-refint \
	openldap-overlay-ppolicy \
	openldap-overlay-sssvlv \
	openldap-overlay-dynlist \
	openldap-passwd-argon2

COPY docker/openldap/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Baked in (rather than relying on a bind mount) so this image is
# self-contained and works as a plain `docker run`/GitHub Actions service
# container with no volumes at all. tests/docker-compose.yml still bind
# mounts the repo over /fixtures for local dev, so editing these files
# doesn't require an image rebuild.
COPY tests/server/openldap /fixtures/tests/server/openldap
COPY docker/openldap /fixtures/docker/openldap

EXPOSE 389

HEALTHCHECK --interval=5s --timeout=5s --retries=20 \
	CMD ldapsearch -x -H ldap://localhost -b dc=Test -s base

ENTRYPOINT ["/entrypoint.sh"]
