//
//  SearchViewModel.swift
//  SwiftHub
//
//  Created by Khoren Markosyan on 6/30/18.
//  Copyright © 2018 Khoren Markosyan. All rights reserved.
//

import Foundation
import RxCocoa
import RxSwift
import RxDataSources

class SearchViewModel: ViewModel, ViewModelType {

    struct Input {
        let trigger: Observable<Void>
        let keywordTrigger: Driver<String>
        let textDidBeginEditing: Driver<Void>
        let segmentSelection: Observable<SearchSegments>
        let selection: Driver<SearchSectionItem>
    }

    struct Output {
        let items: BehaviorRelay<[SearchSection]>
        let textDidBeginEditing: Driver<Void>
        let dismissKeyboard: Driver<Void>
        let repositorySelected: Driver<RepositoryViewModel>
        let userSelected: Driver<UserViewModel>
    }

    func transform(input: Input) -> Output {

        let elements = BehaviorRelay<[SearchSection]>(value: [])

        let trendingRepositoryElements = BehaviorRelay<[TrendingRepository]>(value: [])
        let trendingUserElements = BehaviorRelay<[TrendingUser]>(value: [])

        let repositoryElements = BehaviorRelay<[Repository]>(value: [])
        let userElements = BehaviorRelay<[User]>(value: [])

        let languageElements = BehaviorRelay<LanguageSection?>(value: nil)

        let repositorySelected = PublishSubject<Repository>()
        let userSelected = PublishSubject<User>()

        let dismissKeyboard = input.selection.mapToVoid()

        let keyword = BehaviorRelay(value: "")
        input.keywordTrigger.skip(1).throttle(0.5).distinctUntilChanged().asObservable()
            .bind(to: keyword).disposed(by: rx.disposeBag)

        let showTrendings = BehaviorRelay(value: true)
        keyword.map { $0.isEmpty }
            .bind(to: showTrendings).disposed(by: rx.disposeBag)

        keyword.asObservable().filterEmpty().flatMapLatest({ [weak self] (keyword) -> Observable<[Repository]> in
            guard let self = self else { return Observable.just([]) }
            return self.provider.searchRepositories(query: keyword)
                .trackActivity(self.loading)
                .trackError(self.error)
                .map { $0.items }
        }).subscribe(onNext: { (items) in
            repositoryElements.accept(items)
        }).disposed(by: rx.disposeBag)

        keyword.asObservable().filterEmpty().flatMapLatest({ [weak self] (keyword) -> Observable<[User]> in
            guard let self = self else { return Observable.just([]) }
            return self.provider.searchUsers(query: keyword)
                .trackActivity(self.loading)
                .trackError(self.error)
                .map { $0.items }
        }).subscribe(onNext: { (items) in
            userElements.accept(items)
        }).disposed(by: rx.disposeBag)

        keyword.asDriver().throttle(3.0).drive(onNext: { (keyword) in
            if keyword.isNotEmpty {
                analytics.log(.search(keyword: keyword))
            }
        }).disposed(by: rx.disposeBag)

        Observable.just(()).flatMapLatest { () -> Observable<LanguageSection> in
            return self.provider.languages()
                .trackActivity(self.loading)
                .trackError(self.error)
            }.subscribe(onNext: { (item) in
                languageElements.accept(item)
            }).disposed(by: rx.disposeBag)

        let trendingTrigger = Observable.of(input.trigger, keyword.asObservable().map { $0.isEmpty }.filter { $0 == true }.mapToVoid()).merge()
        trendingTrigger.flatMapLatest { () -> Observable<[TrendingRepository]> in
            return self.provider.trendingRepositories(language: "", since: "daily")
                .trackActivity(self.loading)
                .trackActivity(self.headerLoading)
                .trackError(self.error)
            }.subscribe(onNext: { (items) in
                trendingRepositoryElements.accept(items)
            }).disposed(by: rx.disposeBag)

        trendingTrigger.flatMapLatest { () -> Observable<[TrendingUser]> in
            return self.provider.trendingDevelopers(language: "", since: "daily")
                .trackActivity(self.loading)
                .trackActivity(self.headerLoading)
                .trackError(self.error)
            }.subscribe(onNext: { (items) in
                trendingUserElements.accept(items)
            }).disposed(by: rx.disposeBag)

        input.selection.drive(onNext: { (item) in
            switch item {
            case .trendingRepositoriesItem(let cellViewModel):
                repositorySelected.onNext(Repository(repo: cellViewModel.repository))
            case .trendingUsersItem(let cellViewModel):
                userSelected.onNext(User(user: cellViewModel.user))
            case .repositoriesItem(let cellViewModel):
                repositorySelected.onNext(cellViewModel.repository)
            case .usersItem(let cellViewModel):
                userSelected.onNext(cellViewModel.user)
            }
        }).disposed(by: rx.disposeBag)

        Observable.combineLatest(trendingRepositoryElements, trendingUserElements, repositoryElements, userElements, input.segmentSelection)
            .map { (trendingRepositories, trendingUsers, repositories, users, segment) -> [SearchSection] in
                var elements: [SearchSection] = []
                let showTrendings = showTrendings.value
                let title = showTrendings ? "Trending" : ""
                switch segment {
                case .repositories:
                    if showTrendings {
                        let repositories = trendingRepositories.map({ (repository) -> SearchSectionItem in
                            let cellViewModel = TrendingRepositoryCellViewModel(with: repository)
                            return SearchSectionItem.trendingRepositoriesItem(cellViewModel: cellViewModel)
                        })
                        if repositories.isNotEmpty {
                            elements.append(SearchSection.repositories(title: title, items: repositories))
                        }
                    } else {
                        let repositories = repositories.map({ (repository) -> SearchSectionItem in
                            let cellViewModel = RepositoryCellViewModel(with: repository)
                            return SearchSectionItem.repositoriesItem(cellViewModel: cellViewModel)
                        })
                        if repositories.isNotEmpty {
                            elements.append(SearchSection.repositories(title: title, items: repositories))
                        }
                    }
                case .users:
                    if showTrendings {
                        let users = trendingUsers.map({ (user) -> SearchSectionItem in
                            let cellViewModel = TrendingUserCellViewModel(with: user)
                            return SearchSectionItem.trendingUsersItem(cellViewModel: cellViewModel)
                        })
                        if users.isNotEmpty {
                            elements.append(SearchSection.users(title: title, items: users))
                        }
                    } else {
                        let users = users.map({ (user) -> SearchSectionItem in
                            let cellViewModel = UserCellViewModel(with: user)
                            return SearchSectionItem.usersItem(cellViewModel: cellViewModel)
                        })
                        if users.isNotEmpty {
                            elements.append(SearchSection.users(title: title, items: users))
                        }
                    }
                }
                return elements
        }.bind(to: elements).disposed(by: rx.disposeBag)

        let textDidBeginEditing = input.textDidBeginEditing

        let repositoryDetails = repositorySelected.map({ (repository) -> RepositoryViewModel in
            let viewModel = RepositoryViewModel(repository: repository, provider: self.provider)
            return viewModel
        }).asDriverOnErrorJustComplete()

        let userDetails = userSelected.map({ (user) -> UserViewModel in
            let viewModel = UserViewModel(user: user, provider: self.provider)
            return viewModel
        }).asDriverOnErrorJustComplete()

        return Output(items: elements,
                      textDidBeginEditing: textDidBeginEditing,
                      dismissKeyboard: dismissKeyboard,
                      repositorySelected: repositoryDetails,
                      userSelected: userDetails)
    }
}
