FROM odoo:19.0-20260630 AS build

USER root
RUN pip3 install --no-cache-dir --break-system-packages git-aggregator

COPY addons/custom/repos.yaml /tmp/repos.yaml
WORKDIR /mnt/custom-addons
RUN mkdir -p /mnt/custom-addons && gitaggregate -c /tmp/repos.yaml

FROM odoo:19.0-20260630

USER root

COPY --from=build /mnt/custom-addons /mnt/custom-addons
COPY addons/enterprise /mnt/enterprise-addons
COPY addons/oca /mnt/oca-addons

RUN find /mnt/custom-addons /mnt/enterprise-addons /mnt/oca-addons -name requirements.txt -print0 | xargs -0 -r -n1 pip3 install --no-cache-dir --break-system-packages -r

RUN chown -R odoo:odoo /mnt/custom-addons /mnt/enterprise-addons /mnt/oca-addons

USER odoo
