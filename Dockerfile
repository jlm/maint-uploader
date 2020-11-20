FROM ruby:2.7
WORKDIR /usr/src/app
COPY Gemfile* ./
RUN bundle --version
RUN bundle install
COPY . .

CMD ["./maint-uploader.rb", "--slackpost"]
