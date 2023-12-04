
#!/bin/bash

# Function to update a specific submodule to a target tag and optionally commit the change
update_submodule() {
    local submodule_path=$1

    # Enter the submodule directory or exit on failure
    cd "$submodule_path" || { echo "Error: Failed to enter $submodule_path directory."; exit 1; }

    # Fetch all tags from the remote repository
    git fetch --tags

    # Determine the latest tag
    latest_tag=$(git describe --tags `git rev-list --tags --max-count=1`)

    # Sort and display the list of available tags
    echo "[Available tags in $submodule_path]"
    git tag -l | sort -V

    # Prompt user to select a tag, prefilling with the latest tag
    read -r -p "Select a tag to checkout for $submodule_path (Just ENTER for $latest_tag): " TARGET_TAG
    TARGET_TAG=${TARGET_TAG:-$latest_tag}

    # Checkout to the tag specified by the user
    git checkout "tags/$TARGET_TAG"
    if [ $? -ne 0 ]; then
      echo "Error: Failed to checkout tag $TARGET_TAG in $submodule_path"
      exit 1
    fi

    # Ask the user if they want to commit the change
    read -r -p "Do you want to commit the change for $submodule_path? (ENTER/no): " commit_answer
r
    if [[ $commit_answer != "no" ]]; then
        # Navigate back to the parent directory
        cd ..

        # Stage the changes for the submodule
        git add "$submodule_path"

        # Create a commit
        git commit -m "Update submodule $submodule_path to $TARGET_TAG"
        echo "$submodule_path successfully updated to $TARGET_TAG and committed."
    else
        echo "$submodule_path successfully updated to $TARGET_TAG without committing."
    fi
}

# List of submodules to update
submodules=("mc-infra-connector" "mc-infra-manager" "mc-application-manager" "mc-across-service-manager" "mc-workflow-manager" "mc-cost-optimizer" "mc-iam-manager" "mc-web-console")

# Update each submodule
for submodule in "${submodules[@]}"; do
    update_submodule "$submodule"
done

echo "All submodules have been successfully updated."
echo "ToDo: git log"
echo "ToDo: git push origin"
