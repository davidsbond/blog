serve:
	hugo server

build:
	hugo

deploy:
	hugo deploy

new-post:
	hugo new posts/$(POST_NAME).md
