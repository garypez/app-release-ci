# Container image that runs your code
FROM perl:5.26

WORKDIR /action
COPY merge_report.pl /action/

#CMD ["perl", "/action/merge_report.pl"]