#!/bin/bash

# 파일에 나열된 서브모듈 URL을 읽어오기
submodules_file="submodules.md"

# 파일이 존재하는지 확인
if [[ ! -f $submodules_file ]]; then
    echo "Error: File '$submodules_file' not found."
    exit 1
fi

# 서브모듈 URL을 배열에 읽어오기
readarray -t submodule_urls < "$submodules_file"

# 각 서브모듈을 처리
for submodule_url in "${submodule_urls[@]}"; do
    # 서브모듈 경로 추출 (디렉토리명)
    submodule_path=$(basename $submodule_url .git)

    # 서브모듈 디렉토리가 있는지 확인
    if [[ -d "$submodule_path" ]]; then
        echo "Removing submodule: $submodule_path"

        # 서브모듈 등록 해제
        git submodule deinit -f "$submodule_path"
        
        # 인덱스에서 서브모듈 제거
        git rm -f "$submodule_path"
        
        # .git/modules 내 서브모듈 정보 제거
        rm -rf .git/modules/"$submodule_path"
        
        # 로컬 디렉토리 제거
        rm -rf "$submodule_path"

        echo "Submodule $submodule_path removed successfully."
    else
        echo "Submodule directory $submodule_path does not exist. Skipping."
    fi
done

# 변경 사항 커밋 안내
echo "All listed submodules have been removed."
echo "Run 'git commit -m \"Remove all submodules\"' to commit these changes."
