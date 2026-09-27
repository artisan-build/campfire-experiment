// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails"
import "lib/reverb" // must follow turbo-rails: it replaces turbo's cable consumer
import "initializers"
import "controllers"
