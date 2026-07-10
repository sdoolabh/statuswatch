FROM python:3.12-slim
RUN pip install --no-cache-dir psycopg2-binary==2.9.10
COPY rollup.py /rollup.py
USER 65534
ENTRYPOINT ["python", "/rollup.py"]
