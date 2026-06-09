# Makefile
.PHONY: local-up tofu-validate security-scan

local-up:
    docker-compose up -d
    
tofu-validate:
    tofu fmt
    tofu validate
    
security-scan:
    trivy fs --security-checks vuln,config .
    opa eval -d security/opa-policies/ "data.main.deny' --input
pipelines/nifi-flows/

clean:
    docker-compose down
