// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "lib/reverb/stream_source" // claims <turbo-cable-stream-source> before turbo-rails can
import "@hotwired/turbo-rails"
import "lib/reverb" // replaces turbo's cable consumer for the Stimulus channels
import "initializers"
import "controllers"
