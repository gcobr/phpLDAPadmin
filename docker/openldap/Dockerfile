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

EXPOSE 389

HEALTHCHECK --interval=5s --timeout=5s --retries=20 \
	CMD ldapsearch -x -H ldap://localhost -b dc=Test -s base

ENTRYPOINT ["/entrypoint.sh"]
