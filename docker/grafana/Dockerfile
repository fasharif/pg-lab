# Grafana with the lab's data source and dashboard provisioned at start-up.
FROM grafana/grafana:13.2.3
COPY monitoring/grafana/provisioning/ /etc/grafana/provisioning/
COPY monitoring/grafana/dashboards/ /etc/grafana/dashboards/
