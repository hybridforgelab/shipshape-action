FROM node:latest
RUN apt-get update && apt-get install -y curl
RUN curl -fsSL https://example.com/install.sh | sh
ENV API_TOKEN=changeme
COPY . .
RUN npm install
CMD npm start
